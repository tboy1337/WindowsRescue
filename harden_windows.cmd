@echo off
rem ============================================================================
rem  harden_windows.cmd  -  Windows security hardening (version 2.0.0)
rem
rem  Targets: Windows 10 / 11 and Windows Server 2016 or later (build 10240+).
rem  Must be run from an elevated prompt (or as SYSTEM).
rem
rem  Usage:   harden_windows.cmd [/quiet] [/skip:NAME ...]
rem
rem    /quiet      Never pause or prompt (use for Intune, SCCM, scheduled tasks).
rem                Quiet mode is also enabled automatically when run as SYSTEM.
rem    /skip:NAME  Skip one section. May be repeated. NAME is one of:
rem                restore update firewall uac defender smb network pslog
rem                guest llmnr netbios services
rem
rem  Exit codes:
rem    0  every step succeeded (or was intentionally skipped)
rem    1  precondition failed (not elevated, unsupported OS, no log folder...)
rem    2  finished, but at least one step failed - see the log
rem
rem  Output:  %SystemRoot%\Logs\WindowsHardening\harden_STAMP.log
rem           %SystemRoot%\Logs\WindowsHardening\backup_STAMP\  (prior values,
rem           firewall export, service and feature state). There is no automatic
rem           rollback; use these files to restore anything you need to revert.
rem ============================================================================
setlocal EnableExtensions DisableDelayedExpansion

rem Capture the script path before the working directory changes.
set "SCRIPT_PATH=%~f0"
set "SCRIPT_ARGS=%*"
set "EXITCODE=0"
set "QUIET=0"
set "OK_COUNT=0"
set "WARN_COUNT=0"
set "SKIP_COUNT=0"
set /a MIN_BUILD=10240
set "HELP_SWITCH=/?"
set "ARG_COUNT=0"
set "UPDATE_HOUR=3"

rem ---------------------------------------------------------------------------
rem  Trusted execution environment.
rem  cmd.exe searches the current directory before PATH. Never run from a
rem  user-writable directory (the original script moved to the drive root,
rem  which any user can write to), and never let the current directory be
rem  searched for executables.
rem ---------------------------------------------------------------------------
set "NODEFAULTCURRENTDIRECTORYINEXEPATH=1"
set "PATH=%SystemRoot%\System32;%SystemRoot%"
cd /d "%SystemRoot%\System32" >nul 2>&1
if errorlevel 1 goto :err_cwd

rem ---------------------------------------------------------------------------
rem  A 32-bit host (some deployment tools) on 64-bit Windows would redirect the
rem  registry and System32. Re-launch under the native 64-bit cmd.exe.
rem ---------------------------------------------------------------------------
if not defined PROCESSOR_ARCHITEW6432 goto :arch_ok
if not exist "%SystemRoot%\Sysnative\cmd.exe" goto :arch_ok
"%SystemRoot%\Sysnative\cmd.exe" /d /c call "%SCRIPT_PATH%" %SCRIPT_ARGS%
exit /b %errorlevel%

:arch_ok

rem ---------------------------------------------------------------------------
rem  Arguments
rem ---------------------------------------------------------------------------
:parse_args
if "%~1"=="" goto :args_done
call :parse_one "%~1"
if defined SHOW_HELP goto :usage
if not defined ARG_OK goto :usage_error
set /a ARG_COUNT+=1
shift /1
goto :parse_args

:args_done

rem Running as SYSTEM (SCCM, Intune, scheduled task): there is nobody to answer.
if /i "%USERNAME%"=="%COMPUTERNAME%$" set "QUIET=1"

rem ---------------------------------------------------------------------------
rem  Preconditions
rem ---------------------------------------------------------------------------
rem fltmc works without the Server service; net session is the fallback.
fltmc >nul 2>&1
if not errorlevel 1 goto :admin_ok
net session >nul 2>&1
if not errorlevel 1 goto :admin_ok
echo ERROR: This script requires Administrator privileges.
echo Right-click it and select "Run as administrator".
call :pause_if_interactive
exit /b 1

:admin_ok

set "BUILD="
for /f "tokens=3 delims= " %%B in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /i "CurrentBuildNumber"') do set "BUILD=%%B"
if not defined BUILD goto :build_done
if %BUILD% LSS %MIN_BUILD% goto :err_os

:build_done

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" goto :err_ps

rem ---------------------------------------------------------------------------
rem  Log and backup folders. %SystemRoot%\Logs is writable by administrators
rem  only, so a standard user cannot pre-create or hijack the folder (unlike
rem  %ProgramData%). Access is then limited to SYSTEM and Administrators.
rem ---------------------------------------------------------------------------
set "STAMP="
rem The doubled outer quotes survive the quote stripping that cmd /c applies inside FOR /F.
for /f "usebackq delims=" %%T in (`""%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "Get-Date -Format yyyyMMdd_HHmmss""`) do set "STAMP=%%T"
if not defined STAMP set "STAMP=%RANDOM%%RANDOM%"

set "LOGDIR=%SystemRoot%\Logs\WindowsHardening"
if not exist "%LOGDIR%\" md "%LOGDIR%" >nul 2>&1
if not exist "%LOGDIR%\" goto :err_logdir
icacls "%LOGDIR%" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" >nul 2>&1
set "ACL_RC=%errorlevel%"

set "LOGFILE=%LOGDIR%\harden_%STAMP%.log"
set "BACKUP_DIR=%LOGDIR%\backup_%STAMP%"
set "PRIOR_FILE=%BACKUP_DIR%\prior_registry_values.txt"
md "%BACKUP_DIR%" >nul 2>&1
if not exist "%BACKUP_DIR%\" goto :err_logdir

call :log "+===================================+"
call :log "+ Windows Security Hardening Script +"
call :log "+===================================+"
call :log "[*] Version 2.0.0 started on %COMPUTERNAME%, OS build %BUILD%"
call :log "[*] Log file: %LOGFILE%"
call :log "[*] Command-line arguments processed: %ARG_COUNT%"
call :log "[*] Pre-change backup folder: %BACKUP_DIR%"
if not "%ACL_RC%"=="0" call :log "[WARNING] Could not restrict permissions on %LOGDIR% (exit code %ACL_RC%)"

rem ---------------------------------------------------------------------------
rem  Pre-change state capture (firewall, service, Defender, SMB, accounts)
rem ---------------------------------------------------------------------------
call :log "[*] Capturing pre-change state..."
netsh advfirewall export "%BACKUP_DIR%\firewall_before.wfw" >>"%LOGFILE%" 2>&1
call :report %errorlevel% "Firewall configuration exported to firewall_before.wfw" "Could not export the firewall configuration"
sc qc RemoteRegistry >"%BACKUP_DIR%\service_RemoteRegistry_before.txt" 2>&1
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $f = Join-Path $env:BACKUP_DIR 'prior_state_powershell.txt'; function W($t) { $t | Out-File -FilePath $f -Encoding ascii -Append }; W '--- Get-MpPreference (selected) ---'; try { W (Get-MpPreference | Select-Object DisableRealtimeMonitoring,DisableBehaviorMonitoring,DisableIOAVProtection,DisableScriptScanning,EnableNetworkProtection,PUAProtection | Format-List | Out-String) } catch { W ('unavailable: ' + $_.Exception.Message) }; W '--- Get-SmbServerConfiguration ---'; try { W (Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol | Format-List | Out-String) } catch { W ('unavailable: ' + $_.Exception.Message) }; W '--- SMB1Protocol optional feature ---'; try { W (Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol | Select-Object FeatureName,State | Format-List | Out-String) } catch { W ('unavailable: ' + $_.Exception.Message) }; W '--- Local users ---'; try { W (Get-LocalUser | Select-Object Name,Enabled,SID | Format-List | Out-String) } catch { W ('unavailable: ' + $_.Exception.Message) }; exit 0" >>"%LOGFILE%" 2>&1
call :report %errorlevel% "PowerShell-visible state saved to prior_state_powershell.txt" "Could not save PowerShell-visible state"
reg query "HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces" /s /v NetbiosOptions >>"%PRIOR_FILE%" 2>&1
if errorlevel 1 >>"%PRIOR_FILE%" echo No NetbiosOptions values found before this run

rem ---------------------------------------------------------------------------
rem  System restore point (client editions only; limited to one per 24 hours;
rem  System Restore is off by default on many installs). Failure is not fatal
rem  because the state capture above is always taken.
rem ---------------------------------------------------------------------------
if defined SKIP_RESTORE call :skip "System restore point" & goto :end_restore
call :log "[*] Creating system restore point..."
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { Checkpoint-Computer -Description 'Pre-Hardening Restore Point' -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -WarningVariable cw; if ($cw) { Write-Output ('Restore point not created: ' + ($cw -join ' ')); exit 3 }; Write-Output 'Restore point created'; exit 0 } catch { Write-Output ('Restore point not created: ' + $_.Exception.Message); exit 1 }" >>"%LOGFILE%" 2>&1
if errorlevel 1 goto :restore_failed
call :report 0 "System restore point created" ""
goto :end_restore

:restore_failed
call :log "[WARNING] No restore point was created (System Restore disabled, unsupported edition, or one already exists from the last 24 hours). The pre-change state capture was still taken."

:end_restore

rem ---------------------------------------------------------------------------
rem  Windows Update. AUOptions 4 = automatic download and scheduled install and
rem  only takes effect when ScheduledInstallDay/Time exist (0 = every day,
rem  03:00). On devices managed by Intune, WSUS or Group Policy use /skip:update.
rem ---------------------------------------------------------------------------
if defined SKIP_UPDATE call :skip "Windows Update policy" & goto :end_update
call :log "[*] Configuring Windows Update..."
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" NoAutoUpdate REG_DWORD 0 "Windows Update automatic updates enabled"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" AUOptions REG_DWORD 4 "Windows Update set to automatic download and scheduled install"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" ScheduledInstallDay REG_DWORD 0 "Windows Update install day set to every day"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" ScheduledInstallTime REG_DWORD %UPDATE_HOUR% "Windows Update install hour set to %UPDATE_HOUR%"

:end_update

rem ---------------------------------------------------------------------------
rem  Windows Firewall
rem ---------------------------------------------------------------------------
if defined SKIP_FIREWALL call :skip "Windows Firewall" & goto :end_firewall
call :log "[*] Verifying Windows Firewall is enabled..."
netsh advfirewall set allprofiles state on >>"%LOGFILE%" 2>&1
call :report %errorlevel% "Windows Firewall enabled for all profiles" "Failed to enable Windows Firewall"

:end_firewall

rem ---------------------------------------------------------------------------
rem  User Account Control (EnableLUA changes need a restart to take effect)
rem ---------------------------------------------------------------------------
if defined SKIP_UAC call :skip "User Account Control" & goto :end_uac
call :log "[*] Enabling User Account Control (UAC)..."
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" EnableLUA REG_DWORD 1 "UAC enabled (restart required if it was off)"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" ConsentPromptBehaviorAdmin REG_DWORD 2 "UAC admin prompt set to consent on the secure desktop"

:end_uac

rem ---------------------------------------------------------------------------
rem  Microsoft Defender Antivirus. The settings are read back after writing
rem  because Tamper Protection or policy can silently refuse a change.
rem  PowerShell exit codes: 0 ok, 1 error, 2 not applied, 3 skipped.
rem ---------------------------------------------------------------------------
if defined SKIP_DEFENDER call :skip "Microsoft Defender" & goto :end_defender
call :log "[*] Configuring Windows Defender..."
sc query WinDefend 2>nul | findstr /C:"RUNNING" >nul 2>&1
if errorlevel 1 goto :defender_not_running
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { $s = Get-MpComputerStatus; if (-not $s.AMServiceEnabled) { Write-Output 'Defender engine is disabled; skipping'; exit 3 }; if ($s.AMRunningMode -and $s.AMRunningMode -ne 'Normal') { Write-Output ('Defender running mode is ' + $s.AMRunningMode + '; skipping'); exit 3 }; Set-MpPreference -DisableRealtimeMonitoring $false; Set-MpPreference -DisableBehaviorMonitoring $false; Set-MpPreference -DisableIOAVProtection $false; Set-MpPreference -DisableScriptScanning $false; Set-MpPreference -EnableNetworkProtection Enabled; Set-MpPreference -PUAProtection Enabled; $p = Get-MpPreference; $bad = @(); if ($p.DisableRealtimeMonitoring) { $bad += 'DisableRealtimeMonitoring' }; if ($p.DisableBehaviorMonitoring) { $bad += 'DisableBehaviorMonitoring' }; if ($p.DisableIOAVProtection) { $bad += 'DisableIOAVProtection' }; if ($p.DisableScriptScanning) { $bad += 'DisableScriptScanning' }; if (@('1','Enabled') -notcontains [string]$p.EnableNetworkProtection) { $bad += 'EnableNetworkProtection' }; if (@('1','Enabled') -notcontains [string]$p.PUAProtection) { $bad += 'PUAProtection' }; if ($bad.Count -gt 0) { Write-Output ('Not applied (Tamper Protection or policy?): ' + ($bad -join ', ')); exit 2 }; Write-Output 'Defender preferences verified'; exit 0 } catch { Write-Output ('Defender configuration failed: ' + $_.Exception.Message); exit 1 }" >>"%LOGFILE%" 2>&1
set "RC=%errorlevel%"
if "%RC%"=="3" goto :defender_passive
call :report %RC% "Windows Defender settings applied and verified" "Windows Defender settings were not fully applied (see log)"
goto :end_defender

:defender_passive
call :skip "Microsoft Defender (engine disabled or passive because another antivirus is active)"
goto :end_defender

:defender_not_running
call :skip "Microsoft Defender (WinDefend service is not running)"

:end_defender

rem ---------------------------------------------------------------------------
rem  SMB1. Server side first; the registry value is only a fallback (and needs
rem  a restart). The SMB1Protocol optional feature is removed for the client
rem  side; -NoRestart stops Windows rebooting the machine mid-script.
rem ---------------------------------------------------------------------------
if defined SKIP_SMB call :skip "SMB1 hardening" & goto :end_smb
call :log "[*] Hardening SMB protocol..."
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force; if ((Get-SmbServerConfiguration).EnableSMB1Protocol) { Write-Output 'SMB1 server still enabled after change'; exit 2 }; exit 0 } catch { Write-Output $_.Exception.Message; exit 1 }" >>"%LOGFILE%" 2>&1
set "RC=%errorlevel%"
if "%RC%"=="0" goto :smb_server_ok
call :log "[WARNING] Set-SmbServerConfiguration failed (exit code %RC%); trying registry fallback..."
call :regadd "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" SMB1 REG_DWORD 0 "SMB1 server disabled via registry (restart required)"
goto :smb_client

:smb_server_ok
call :report 0 "SMB1 server protocol disabled" ""

:smb_client
call :log "[*] Checking the SMB1Protocol optional feature (this can take a minute)..."
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol; if ($f -and $f.State -eq 'Enabled') { $r = Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart; Write-Output 'SMB1Protocol optional feature disabled'; if ($r.RestartNeeded) { Write-Output 'Restart required to finish removing SMB1' } } else { Write-Output 'SMB1Protocol optional feature is not enabled; nothing to do' }; exit 0 } catch { Write-Output $_.Exception.Message; exit 1 }" >>"%LOGFILE%" 2>&1
call :report %errorlevel% "SMB1 client feature checked (disabled if it was present)" "Could not check or disable the SMB1Protocol optional feature (see log)"

:end_smb

rem ---------------------------------------------------------------------------
rem  TCP/IP hardening (IPv4 and IPv6)
rem ---------------------------------------------------------------------------
if defined SKIP_NETWORK call :skip "Network security settings" & goto :end_network
call :log "[*] Configuring network security settings..."
call :regadd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" EnableICMPRedirect REG_DWORD 0 "ICMP redirects disabled"
call :regadd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" DisableIPSourceRouting REG_DWORD 2 "IPv4 source routing disabled"
call :regadd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" DisableIPSourceRouting REG_DWORD 2 "IPv6 source routing disabled"

:end_network

rem ---------------------------------------------------------------------------
rem  PowerShell logging (Windows PowerShell 5.1). Module logging only records
rem  anything when ModuleNames contains the value * (added below). The
rem  PowerShell Operational event log is small by default; consider enlarging it.
rem ---------------------------------------------------------------------------
if defined SKIP_PSLOG call :skip "PowerShell logging" & goto :end_pslog
call :log "[*] Configuring PowerShell security..."
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" EnableScriptBlockLogging REG_DWORD 1 "PowerShell script block logging enabled"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" EnableModuleLogging REG_DWORD 1 "PowerShell module logging enabled"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames" "*" REG_SZ "*" "PowerShell module logging set to cover all modules"

:end_pslog

rem ---------------------------------------------------------------------------
rem  Built-in Guest account, found by its well-known SID (RID 501) so the
rem  script also works on non-English Windows where the account is renamed.
rem ---------------------------------------------------------------------------
if defined SKIP_GUEST call :skip "Guest account" & goto :end_guest
call :log "[*] Disabling Guest account..."
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { $g = Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' }; if (-not $g) { Write-Output 'Built-in Guest account not found'; exit 0 }; if ($g.Enabled) { Disable-LocalUser -SID $g.SID; Write-Output ('Disabled built-in Guest account: ' + $g.Name) } else { Write-Output ('Built-in Guest account already disabled: ' + $g.Name) }; exit 0 } catch { Write-Output $_.Exception.Message; exit 1 }" >>"%LOGFILE%" 2>&1
call :report %errorlevel% "Guest account disabled (or already disabled)" "Failed to disable the Guest account (not supported on domain controllers)"

:end_guest

rem ---------------------------------------------------------------------------
rem  LLMNR
rem ---------------------------------------------------------------------------
if defined SKIP_LLMNR call :skip "LLMNR" & goto :end_llmnr
call :log "[*] Disabling LLMNR..."
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" EnableMulticast REG_DWORD 0 "LLMNR disabled"

:end_llmnr

rem ---------------------------------------------------------------------------
rem  NetBIOS over TCP/IP. The per-interface registry value covers every adapter,
rem  including disconnected ones; the WMI method applies it to live adapters.
rem  WMI success codes are 0 and 1 (1 = restart required).
rem ---------------------------------------------------------------------------
if defined SKIP_NETBIOS call :skip "NetBIOS over TCP/IP" & goto :end_netbios
call :log "[*] Disabling NetBIOS over TCP/IP..."
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { $fail = 0; $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'; Get-ChildItem -Path $base | Where-Object { $_.PSChildName -like 'Tcpip_*' } | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 2 -Type DWord }; Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { $r = Invoke-CimMethod -InputObject $_ -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 }; if (@(0,1) -notcontains [int]$r.ReturnValue) { $fail++; Write-Output ('SetTcpipNetbios failed on ' + $_.Description + ' with code ' + $r.ReturnValue) } }; if ($fail -gt 0) { exit 2 }; exit 0 } catch { Write-Output $_.Exception.Message; exit 1 }" >>"%LOGFILE%" 2>&1
call :report %errorlevel% "NetBIOS over TCP/IP disabled on all interfaces (adapters added later keep their DHCP default)" "Failed to disable NetBIOS on one or more adapters (see log)"

:end_netbios

rem ---------------------------------------------------------------------------
rem  Services
rem ---------------------------------------------------------------------------
if defined SKIP_SERVICES call :skip "Service hardening" & goto :end_services
call :log "[*] Disabling unnecessary services..."
sc query RemoteRegistry >nul 2>&1
if errorlevel 1 goto :rr_absent
sc config RemoteRegistry start= disabled >>"%LOGFILE%" 2>&1
call :report %errorlevel% "Remote Registry service set to Disabled" "Failed to disable the Remote Registry service"
sc query RemoteRegistry 2>nul | findstr /C:"RUNNING" >nul 2>&1
if errorlevel 1 goto :end_services
sc stop RemoteRegistry >>"%LOGFILE%" 2>&1
call :report %errorlevel% "Remote Registry service stopped" "Failed to stop the Remote Registry service"
goto :end_services

:rr_absent
call :log "[INFO] Remote Registry service is not installed; nothing to do"

:end_services

rem ---------------------------------------------------------------------------
rem  Summary
rem ---------------------------------------------------------------------------
if %WARN_COUNT% GTR 0 set "EXITCODE=2"
call :log "+=====================+"
call :log "+ Hardening Complete! +"
call :log "+=====================+"
call :log "[*] Result: %OK_COUNT% succeeded, %WARN_COUNT% failed, %SKIP_COUNT% skipped. Exit code %EXITCODE%."
call :log "[*] Log: %LOGFILE%"
call :log "[*] Prior values and exports: %BACKUP_DIR%"
call :log "IMPORTANT: Restart the computer for all changes to take effect (UAC, SMB1, NetBIOS)."
call :pause_if_interactive
exit /b %EXITCODE%

rem ============================================================================
rem  Subroutines
rem ============================================================================

rem :log - print a message and append it, timestamped, to the log file.
rem   %1 = message. It must not contain metacharacters or literal percent signs.
rem   Returns 0.
:log
echo(%~1
>>"%LOGFILE%" echo [%date% %time: =0%] %~1
exit /b 0

rem :parse_one - classify one command-line argument.
rem   %1 = argument. Sets ARG_OK when it is valid, QUIET for /quiet, SHOW_HELP for help
rem   and SKIP_NAME for /skip:NAME. Returns 0.
:parse_one
set "ARG=%~1"
set "ARG_OK="
if /i "%ARG%"=="/quiet" set "QUIET=1" & set "ARG_OK=1"
if /i "%ARG%"=="/q" set "QUIET=1" & set "ARG_OK=1"
if /i "%ARG%"=="%HELP_SWITCH%" set "SHOW_HELP=1" & set "ARG_OK=1"
if /i "%ARG%"=="/help" set "SHOW_HELP=1" & set "ARG_OK=1"
set "ARG_HEAD=%ARG:~0,6%"
set "ARG_TAIL=%ARG:~6%"
if /i "%ARG_HEAD%"=="/skip:" call :parse_skip "%ARG_TAIL%"
exit /b 0

rem :parse_skip - mark one section as skipped.
rem   %1 = section name taken from /skip:NAME. Sets SKIP_NAME and ARG_OK when the
rem   name is known. Returns 0.
:parse_skip
for %%N in (RESTORE UPDATE FIREWALL UAC DEFENDER SMB NETWORK PSLOG GUEST LLMNR NETBIOS SERVICES) do if /i "%%N"=="%~1" (set "SKIP_%%N=1" & set "ARG_OK=1")
exit /b 0

rem :report - count and log the outcome of one step.
rem   %1 = exit code (0 = success), %2 = success message, %3 = failure message.
rem   Increments OK_COUNT or WARN_COUNT. Returns 0.
:report
if "%~1"=="0" goto :report_ok
set /a WARN_COUNT+=1
call :log "[WARNING] %~3 (exit code %~1)"
exit /b 0

rem :report_ok - success branch of :report. %2 = success message. Returns 0.
:report_ok
set /a OK_COUNT+=1
call :log "[OK] %~2"
exit /b 0

rem :skip - count and log a section that was intentionally not run.
rem   %1 = description. Increments SKIP_COUNT. Returns 0.
:skip
set /a SKIP_COUNT+=1
call :log "[SKIP] %~1"
exit /b 0

rem :regadd - back up the current value, set a new one, and report the result.
rem   %1 = key, %2 = value name, %3 = type, %4 = data, %5 = success message.
rem   Returns 0; the outcome is recorded through :report.
:regadd
call :snap_reg "%~1" "%~2"
reg add "%~1" /v "%~2" /t "%~3" /d "%~4" /f >>"%LOGFILE%" 2>&1
call :report %errorlevel% "%~5" "Failed to set %~2 under %~1"
exit /b 0

rem :snap_reg - append a registry value, or a note that it is absent, to the backup file.
rem   %1 = key, %2 = value name. Returns 0.
:snap_reg
>>"%PRIOR_FILE%" echo [%~1] %~2
reg query "%~1" /v "%~2" >>"%PRIOR_FILE%" 2>&1
if errorlevel 1 >>"%PRIOR_FILE%" echo Value not present before this run
exit /b 0

rem :pause_if_interactive - wait for a key unless /quiet or SYSTEM was detected.
rem   Returns 0.
:pause_if_interactive
if "%QUIET%"=="0" pause
exit /b 0

rem ============================================================================
rem  Early exits (before logging exists)
rem ============================================================================

rem :err_cwd - the trusted working directory could not be entered. Exits 1.
:err_cwd
echo ERROR: Could not change to %SystemRoot%\System32.
exit /b 1

rem :err_os - the Windows build is older than MIN_BUILD. Exits 1.
:err_os
echo ERROR: Windows build %BUILD% is not supported. Windows 10 (build %MIN_BUILD%) or later is required.
call :pause_if_interactive
exit /b 1

rem :err_ps - Windows PowerShell is missing. Exits 1.
:err_ps
echo ERROR: Windows PowerShell was not found at the expected location.
call :pause_if_interactive
exit /b 1

rem :err_logdir - the log or backup folder could not be created. Exits 1.
:err_logdir
echo ERROR: Could not create the log and backup folders under %SystemRoot%\Logs\WindowsHardening.
call :pause_if_interactive
exit /b 1

rem :usage_error - report an invalid argument, then show the usage text. Exits 1.
:usage_error
echo ERROR: Unknown or invalid argument.
echo.
call :usage_text
exit /b 1

rem :usage - show the usage text. Exits 0.
:usage
call :usage_text
exit /b 0

rem :usage_text - print the command-line help. Returns 0.
:usage_text
echo Usage: harden_windows.cmd [/quiet] [/skip:NAME ...]
echo.
echo   /quiet       Never pause (for unattended deployment).
echo   /skip:NAME   Skip one section; may be repeated. NAME is one of:
echo                restore update firewall uac defender smb network pslog
echo                guest llmnr netbios services
echo.
echo Exit codes: 0 success, 1 precondition failed, 2 completed with failures.
exit /b 0
