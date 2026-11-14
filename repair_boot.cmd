@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem  repair_boot.cmd - Windows Recovery Environment repair helper, version 3.1
rem
rem  Run from Windows RE (Troubleshoot, Advanced options, Command Prompt) or from
rem  Windows installation media (Repair your computer, then Command Prompt).
rem  The script refuses to run inside a normal Windows session.
rem
rem  Operations (each can be run on its own):
rem    1  chkdsk on the Windows volume
rem    2  DISM /RestoreHealth and SFC against the offline Windows image
rem    3  Boot repair with bcdboot (UEFI/GPT or BIOS/MBR, detected from the disk)
rem    4  Schedule Windows Memory Diagnostic for the next boot
rem    5  All of the above in order
rem    6  Advanced boot repair (always replaces the BCD store with a fresh one)
rem    8  Unlock a BitLocker drive and re-detect Windows
rem
rem  Safety rules built into this script:
rem    - No partition is ever deleted or created.
rem    - The EFI system partition is only reformatted after typing FORMAT.
rem    - The BCD store is backed up before it is touched and restored if
rem      bcdboot fails.
rem    - Boot repair needs an explicit Y after the target is displayed.
rem
rem  Logs: X:\repair_boot\repair_boot.log, copied to
rem        <Windows drive>\repair_boot_logs\run.N when the script exits.
rem ============================================================================

set "SCRIPT_VERSION=3.0"
if /i "%~1"=="/?" goto usage
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage

call :check_winre
if errorlevel 1 (
    echo ERROR: This script must be run from the Windows Recovery Environment or Windows PE.
    echo Start the PC from recovery media, or use Troubleshoot, Advanced options, Command Prompt.
    echo Running it inside a normal Windows session is blocked on purpose.
    exit /b 1
)

set "WORKDIR=%SystemDrive%\repair_boot"
set "LOGFILE=%WORKDIR%\repair_boot.log"
set "DP_SCRIPT=%WORKDIR%\dp_script.txt"
set "DP_OUT=%WORKDIR%\dp_out.txt"
set "DRIVES_FILE=%WORKDIR%\drives.txt"
if not exist "%WORKDIR%\" md "%WORKDIR%" >nul 2>&1
if not exist "%WORKDIR%\" (
    echo ERROR: Could not create the working folder %WORKDIR%.
    exit /b 1
)

set "RES_CHKDSK=not run"
set "RES_DISM=not run"
set "RES_SFC=not run"
set "RES_BOOT=not run"
set "RES_MEM=not run"
set "FORCE_FRESH=0"
set "CK_SURFACE=N"
set "WIN_DRIVE="
set "TARGET_WINDIR="
set "FW_MODE=Unknown"
set "DISK_STYLE=Unknown"
set "BOOT_MODE=Unknown"
set "TARGET_DISK="
set "ESP_PART="
set "SYS_VOL="
set "SYS_DRIVE="
set "SYS_MOUNTED="
set "MOUNT_METHOD="
set "BCD_PATH="
set "DP_USED="
rem  These are assigned by name in helpers (set "%~2=..." in :ask_yn, WIN_n in
rem  :detect_windows, RESULT_VAR_RC in :dism_check). Clearing them here means a
rem  value inherited from the environment can never be mistaken for an answer.
set "ANS_ADV="
set "ANS_REVERT="
set "ANS_BOOT="
set "ANS_MEM="
set "ANS_REBUILD="
set "ANS_FORCE="
set "ALL_MEM="
set "WIN_1="
set "ST_CHECK="
set "ST_SCAN="
set "ST_CHECK_RC="
set "ST_SCAN_RC="

>>"%LOGFILE%" echo ================================================================
>>"%LOGFILE%" echo repair_boot.cmd v%SCRIPT_VERSION% session started %DATE% %TIME: =0%

echo ==============================================================
echo   Windows Recovery Environment Repair Script  v%SCRIPT_VERSION%
echo ==============================================================
echo.

call :check_tools
if defined MISSING_REQUIRED (
    echo ERROR: Required tools are missing from this environment: !MISSING_REQUIRED!
    call :info "Missing required tools: !MISSING_REQUIRED!"
    exit /b 1
)

call :ensure_windows
if errorlevel 1 (
    call :cleanup
    exit /b 1
)

call :detect_environment

goto menu

rem ============================================================================
rem  MENU
rem ============================================================================
:menu
cls
echo ==============================================================
echo   Windows Recovery Environment Repair Script  v%SCRIPT_VERSION%
echo ==============================================================
echo   Windows installation : !WIN_DRIVE!
echo   Firmware mode        : !FW_MODE!
echo   Disk partition style : !DISK_STYLE!
echo   Boot repair mode     : !BOOT_MODE!
echo ==============================================================
echo   1  Check and repair the file system     chkdsk
echo   2  Repair system files                  DISM and SFC
echo   3  Repair boot files and BCD            bcdboot
echo   4  Schedule memory diagnostic on next boot
echo   5  Run ALL of the above in order        recommended
echo   6  Advanced boot repair                 always rebuilds a fresh BCD
echo   7  Exit
echo   8  Unlock a BitLocker drive and re-detect Windows
echo ==============================================================
set "choice="
set /p "choice=Enter your choice (1-8): "
if "!choice!"=="1" goto do_chkdsk
if "!choice!"=="2" goto do_sfcdism
if "!choice!"=="3" goto do_startup
if "!choice!"=="4" goto do_memory
if "!choice!"=="5" goto do_all
if "!choice!"=="6" goto do_advanced
if "!choice!"=="7" goto finish
if "!choice!"=="8" goto do_unlock
echo Invalid choice.
goto menu_pause

:menu_pause
echo.
pause
goto menu

:do_chkdsk
call :ask_surface
call :run_chkdsk
goto menu_pause

:do_sfcdism
call :run_sfcdism
goto menu_pause

:do_startup
set "FORCE_FRESH=0"
call :run_startup
goto menu_pause

:do_memory
call :run_memdiag N
goto menu_pause

:do_advanced
echo.
echo ===== ADVANCED BOOT REPAIR =====
echo This replaces the BCD store with a freshly generated one. Boot entries for
echo other operating systems on this PC will be removed from the BCD.
echo The old store is kept as a backup file next to it.
call :ask_yn "Continue with advanced boot repair?" ANS_ADV N
if /i not "!ANS_ADV!"=="Y" goto menu_pause
set "FORCE_FRESH=1"
call :run_startup
set "FORCE_FRESH=0"
goto menu_pause

:do_unlock
call :unlock_bitlocker
call :ensure_windows
if errorlevel 1 goto finish
call :detect_environment
goto menu_pause

:do_all
echo.
echo Running all repairs in order: disk check, system files, boot repair, then
echo an optional memory test. This can take one to several hours on large disks.
call :ask_surface
call :ask_yn "Schedule the memory diagnostic for the next boot at the end?" ALL_MEM N
set "FORCE_FRESH=0"
call :run_chkdsk
call :run_sfcdism
call :run_startup
if /i "!ALL_MEM!"=="Y" call :run_memdiag Y
goto finish

rem ============================================================================
rem  ENVIRONMENT CHECKS
rem ============================================================================
:check_winre
set "IN_PE="
reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1
if not errorlevel 1 set "IN_PE=1"
if not defined IN_PE (
    reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE" >nul 2>&1
    if not errorlevel 1 set "IN_PE=1"
)
if not defined IN_PE if /i "%SystemDrive%"=="X:" set "IN_PE=1"
if not defined IN_PE exit /b 1
exit /b 0

rem  Verifies the required tools are on PATH (MISSING_REQUIRED) and records which optional
rem  tools exist (HAVE_*).
:check_tools
set "MISSING_REQUIRED="
for %%T in (diskpart.exe dism.exe sfc.exe chkdsk.exe bcdboot.exe bcdedit.exe reg.exe findstr.exe attrib.exe) do (
    if "%%~$PATH:T"=="" set "MISSING_REQUIRED=!MISSING_REQUIRED! %%T"
)
set "HAVE_BOOTREC="
set "HAVE_BOOTSECT="
set "HAVE_MANAGEBDE="
set "HAVE_WPEUTIL="
set "HAVE_FSUTIL="
for %%T in (bootrec.exe) do if not "%%~$PATH:T"=="" set "HAVE_BOOTREC=1"
for %%T in (bootsect.exe) do if not "%%~$PATH:T"=="" set "HAVE_BOOTSECT=1"
for %%T in (manage-bde.exe) do if not "%%~$PATH:T"=="" set "HAVE_MANAGEBDE=1"
for %%T in (wpeutil.exe) do if not "%%~$PATH:T"=="" set "HAVE_WPEUTIL=1"
for %%T in (fsutil.exe) do if not "%%~$PATH:T"=="" set "HAVE_FSUTIL=1"
call :log "Optional tools: bootrec=!HAVE_BOOTREC! bootsect=!HAVE_BOOTSECT! manage-bde=!HAVE_MANAGEBDE!"
call :log "Optional tools: wpeutil=!HAVE_WPEUTIL! fsutil=!HAVE_FSUTIL!"
exit /b 0

rem ---------------------------------------------------------------------------
rem  Find the Windows installation. Returns 0 found, 1 none found, 2 cancelled.
rem ---------------------------------------------------------------------------
:detect_windows
set "WIN_COUNT=0"
set "WIN_DRIVE="
set "TARGET_WINDIR="
echo Detecting Windows installations...
rem  A drive counts as Windows when it holds the SYSTEM hive or ntoskrnl.exe.
rem  The recovery RAM disk is skipped, and the list leaves out X and floppy A and B.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if /i not "%%D:"=="%SystemDrive%" (
        set "DW_FOUND="
        if exist "%%D:\Windows\System32\config\SYSTEM" set "DW_FOUND=1"
        if exist "%%D:\Windows\System32\ntoskrnl.exe" set "DW_FOUND=1"
        if defined DW_FOUND (
            set /a WIN_COUNT+=1
            set "WIN_!WIN_COUNT!=%%D:"
            call :log "Windows installation candidate: %%D:"
        )
    )
)
if !WIN_COUNT! equ 0 exit /b 1
if !WIN_COUNT! equ 1 (
    set "WIN_DRIVE=!WIN_1!"
    goto detect_windows_done
)
echo.
echo Multiple Windows installations were found:
for /l %%I in (1,1,!WIN_COUNT!) do (
    echo.
    echo   %%I   !WIN_%%I!
    vol !WIN_%%I!
)

:detect_windows_pick
echo.
set "DW_SEL="
set /p "DW_SEL=Select the installation to repair, 1 to !WIN_COUNT!, or Q to quit: "
if /i "!DW_SEL!"=="Q" exit /b 2
for /l %%I in (1,1,!WIN_COUNT!) do (
    if "!DW_SEL!"=="%%I" set "WIN_DRIVE=!WIN_%%I!"
)
if not defined WIN_DRIVE (
    echo Invalid selection.
    goto detect_windows_pick
)

:detect_windows_done
set "TARGET_WINDIR=!WIN_DRIVE!\Windows"
echo Using Windows installation on !WIN_DRIVE!
call :log "Selected Windows installation !WIN_DRIVE!"
exit /b 0

rem  Finds a Windows installation, offering a BitLocker unlock and a rescan when none is
rem  visible. Returns 1 when the user quits.
:ensure_windows
call :detect_windows
if not errorlevel 1 exit /b 0
if errorlevel 2 exit /b 1

:ensure_windows_none
echo.
echo No Windows installation was found on any visible drive.
echo   - If the drive is protected by BitLocker it must be unlocked first.
echo   - If no disk is visible at all, load the storage driver with drvload.
echo.
echo   U  unlock a BitLocker drive with its recovery password
echo   R  rescan drives
echo   Q  quit
set "EW_ANS="
set /p "EW_ANS=Choose U, R or Q: "
if /i "!EW_ANS!"=="Q" exit /b 1
if /i "!EW_ANS!"=="U" call :unlock_bitlocker
call :detect_windows
if not errorlevel 1 exit /b 0
if errorlevel 2 exit /b 1
goto ensure_windows_none

rem ---------------------------------------------------------------------------
rem  Firmware mode, partition style of the Windows disk, system partition.
rem  Failures here are not fatal. Boot repair asks the user when unsure.
rem ---------------------------------------------------------------------------
:detect_environment
call :unmount_system_partition
set "FW_MODE=Unknown"
set "DISK_STYLE=Unknown"
set "BOOT_MODE=Unknown"
set "TARGET_DISK="
set "ESP_PART="
set "SYS_VOL="
set "SYS_DRIVE="
set "SYS_MOUNTED="
set "MOUNT_METHOD="
set "BCD_PATH="
echo.
echo Inspecting firmware mode and disk layout. This takes a few seconds...

if defined HAVE_WPEUTIL wpeutil UpdateBootInfo >nul 2>&1
set "FW_RAW="
for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v PEFirmwareType 2^>nul ^| findstr /c:"PEFirmwareType"') do set "FW_RAW=%%B"
if "!FW_RAW!"=="0x1" set "FW_MODE=BIOS"
if "!FW_RAW!"=="0x2" set "FW_MODE=UEFI"
call :info "Firmware mode of this environment: !FW_MODE! raw value !FW_RAW!"

call :dp_begin
call :dp_add "select volume !WIN_DRIVE:~0,1!"
call :dp_add "detail volume"
call :dp_run
if errorlevel 1 (
    call :info "WARNING: diskpart could not inspect volume !WIN_DRIVE!"
    exit /b 1
)
for /f "tokens=2 delims=* " %%A in ('findstr /r /c:"^\* *Disk [0-9]" /c:"^ *Disk [0-9]" "%DP_OUT%"') do if not defined TARGET_DISK set "TARGET_DISK=%%A"
if not defined TARGET_DISK (
    call :info "WARNING: could not determine which disk holds !WIN_DRIVE!"
    exit /b 1
)
call :info "Windows volume !WIN_DRIVE! is on disk !TARGET_DISK!"

call :dp_begin
call :dp_add "select disk !TARGET_DISK!"
call :dp_add "detail disk"
call :dp_add "list partition"
call :dp_run
if errorlevel 1 (
    call :info "WARNING: diskpart could not inspect disk !TARGET_DISK!"
    exit /b 1
)

findstr /r /c:"{[0-9A-Fa-f]*-[0-9A-Fa-f]*-[0-9A-Fa-f]*-" "%DP_OUT%" >nul 2>&1
if not errorlevel 1 set "DISK_STYLE=GPT"
if "!DISK_STYLE!"=="Unknown" (
    findstr /r /c:": [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$" "%DP_OUT%" >nul 2>&1
    if not errorlevel 1 set "DISK_STYLE=MBR"
)
if "!DISK_STYLE!"=="GPT" set "BOOT_MODE=UEFI"
if "!DISK_STYLE!"=="MBR" set "BOOT_MODE=BIOS"

for /f "tokens=2 delims= " %%A in ('findstr /i /r /c:"Partition [0-9][0-9]* *System" "%DP_OUT%"') do if not defined ESP_PART set "ESP_PART=%%A"
if "!DISK_STYLE!"=="MBR" (
    for /f "delims=" %%A in ('findstr /i /r /c:"^[ *]*Volume [0-9].*Healthy  *System" "%DP_OUT%"') do if not defined SYS_VOL call :parse_sysvol "%%A"
)

call :info "Disk !TARGET_DISK! style=!DISK_STYLE! boot mode=!BOOT_MODE!"
call :info "EFI partition=!ESP_PART! BIOS system volume=!SYS_VOL! existing letter=!SYS_DRIVE!"
exit /b 0

rem  Parses one line of the diskpart volume table. The Ltr column is at a fixed
rem  offset (character 15). A volume that already has a letter is used as it is.
:parse_sysvol
set "PS_LINE=%~1"
for /f "tokens=2 delims=* " %%N in ("!PS_LINE!") do set "SYS_VOL=%%N"
set "PS_LTR=!PS_LINE:~15,1!"
if "!PS_LTR!"==" " exit /b 0
call :is_letter PS_LTR
if errorlevel 1 exit /b 0
set "SYS_DRIVE=!PS_LTR!:"
set "MOUNT_METHOD=NONE"
set "BCD_PATH=!SYS_DRIVE!\Boot\BCD"
exit /b 0

rem ============================================================================
rem  LOGGING AND PROMPT HELPERS
rem ============================================================================
:log
>>"%LOGFILE%" echo [%TIME: =0%] %~1
exit /b 0

rem  call :info "message"   - prints a message and appends it to the log
:info
echo(%~1
>>"%LOGFILE%" echo [%TIME: =0%] %~1
exit /b 0

rem  call :ask_yn "prompt" RESULT_VAR DEFAULT   - RESULT_VAR becomes Y or N
:ask_yn
set "%~2="
set "YN_ANS="
set /p "YN_ANS=%~1 [Y/N, default %~3]: "
if not defined YN_ANS set "YN_ANS=%~3"
set "YN_ANS=!YN_ANS:~0,1!"
if /i "!YN_ANS!"=="Y" (
    set "%~2=Y"
) else (
    set "%~2=N"
)
call :log "Prompt answered %~2=!%~2! for: %~1"
exit /b 0

rem  call :ask_typed "prompt" EXPECTED_WORD   - returns 0 only on an exact match
:ask_typed
set "TY_ANS="
set /p "TY_ANS=%~1: "
if /i "!TY_ANS!"=="%~2" exit /b 0
exit /b 1

rem  call :digits_only VARNAME   - returns 0 if the variable is non-empty and
rem  holds only the characters 0 to 9. Digits are removed by string substitution
rem  because FOR /F skips any line that starts with its eol character (default
rem  a semicolon), which would let a value such as ;abc pass a delims check.
:digits_only
set "DO_REST=!%~1!"
if not defined DO_REST exit /b 1
for %%N in (0 1 2 3 4 5 6 7 8 9) do (
    if defined DO_REST set "DO_REST=!DO_REST:%%N=!"
)
if defined DO_REST exit /b 1
exit /b 0

rem  call :is_digits VARNAME   - returns 0 if the variable holds 1 to 4 digits
:is_digits
set "ID_VAL=!%~1!"
if not defined ID_VAL exit /b 1
if not "!ID_VAL:~4!"=="" exit /b 1
call :digits_only ID_VAL
exit /b !errorlevel!

rem  call :is_letter VARNAME   - returns 0 if the variable holds one letter A to Z
:is_letter
set "IL_VAL=!%~1!"
set "IL_OK="
if not defined IL_VAL exit /b 1
for %%L in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if /i "!IL_VAL!"=="%%L" set "IL_OK=1"
if defined IL_OK exit /b 0
exit /b 1

rem  call :ask_number RESULT_VAR "prompt"   - returns 1 if the user typed Q
:ask_number
set "AN_VAR=%~1"

:ask_number_loop
set "AN_IN="
set /p "AN_IN=%~2 (or Q to cancel): "
if /i "!AN_IN!"=="Q" exit /b 1
call :is_digits AN_IN
if errorlevel 1 (
    echo Please enter digits only.
    goto ask_number_loop
)
set "!AN_VAR!=!AN_IN!"
exit /b 0

rem  call :unique_name "base" RESULT_VAR   - RESULT_VAR becomes base.N, unused
:unique_name
set "UN_N=0"

:unique_name_loop
set /a UN_N+=1
if !UN_N! gtr 999 exit /b 1
if exist "%~1.!UN_N!" goto unique_name_loop
set "%~2=%~1.!UN_N!"
exit /b 0

rem  call :wait_secs N   - sleeps about N seconds using ping, harmless if absent
:wait_secs
set /a WS_COUNT=%~1+1
ping -n !WS_COUNT! 127.0.0.1 >nul 2>&1
exit /b 0

rem  Asks whether chkdsk should run a full surface scan. The answer is stored in CK_SURFACE.
:ask_surface
call :ask_yn "Include a full surface scan, chkdsk /r? It can take hours on large disks" CK_SURFACE N
exit /b 0

rem ============================================================================
rem  DISKPART HELPERS
rem  diskpart.exe documents exit code 0 as success and 1 to 5 as failures, and it
rem  stops a script at the first failing command. Consecutive diskpart runs can
rem  fail when started too quickly, so runs are spaced out and retried once.
rem ============================================================================
:dp_begin
type nul > "%DP_SCRIPT%"
exit /b 0

rem  Appends one line to the diskpart script.
:dp_add
>>"%DP_SCRIPT%" echo(%~1
exit /b 0

rem  Runs the diskpart script, logs it, retries once after a pause, and returns diskpart's exit
rem  code.
:dp_run
if defined DP_USED call :wait_secs 5
set "DP_USED=1"
diskpart /s "%DP_SCRIPT%" > "%DP_OUT%" 2>&1
set "DP_RC=!errorlevel!"
if not "!DP_RC!"=="0" (
    call :log "diskpart returned !DP_RC!, retrying once after a pause"
    call :wait_secs 15
    diskpart /s "%DP_SCRIPT%" > "%DP_OUT%" 2>&1
    set "DP_RC=!errorlevel!"
)
>>"%LOGFILE%" echo ---- diskpart exit code !DP_RC!, script follows
>>"%LOGFILE%" type "%DP_SCRIPT%"
>>"%LOGFILE%" echo ---- diskpart output follows
>>"%LOGFILE%" type "%DP_OUT%"
exit /b !DP_RC!

rem  Picks a drive letter that is not in use. Result in FREE_LETTER, no colon.
:find_free_letter
set "FREE_LETTER="
type nul > "%DRIVES_FILE%"
if defined HAVE_FSUTIL fsutil fsinfo drives > "%DRIVES_FILE%" 2>nul
for %%D in (S T U V W R Q P O N M L K J I H G F E) do (
    if not defined FREE_LETTER (
        findstr /i /c:" %%D:" "%DRIVES_FILE%" >nul 2>&1
        if errorlevel 1 if not exist "%%D:\" set "FREE_LETTER=%%D"
    )
)
if not defined FREE_LETTER exit /b 1
exit /b 0

rem ============================================================================
rem  SYSTEM PARTITION (EFI system partition or BIOS active partition)
rem ============================================================================
rem  Sets SYS_DRIVE and BCD_PATH. Returns 0 on success.
:mount_system_partition
if defined SYS_DRIVE exit /b 0
if /i "!BOOT_MODE!"=="UEFI" goto mount_uefi
if /i "!BOOT_MODE!"=="BIOS" goto mount_bios
exit /b 1

:mount_uefi
if not defined TARGET_DISK goto mount_uefi_manual
if not defined ESP_PART goto mount_uefi_manual
goto mount_uefi_assign

:mount_uefi_manual
call :manual_pick_esp
if errorlevel 1 exit /b 1

:mount_uefi_assign
call :find_free_letter
if errorlevel 1 (
    call :info "ERROR: no free drive letter is available for the EFI system partition"
    exit /b 1
)
call :dp_begin
call :dp_add "select disk !TARGET_DISK!"
call :dp_add "select partition !ESP_PART!"
call :dp_add "assign letter=!FREE_LETTER!"
call :dp_run
if errorlevel 1 (
    call :info "ERROR: diskpart could not assign a drive letter to the EFI system partition"
    exit /b 1
)
set "SYS_DRIVE=!FREE_LETTER!:"
set "SYS_MOUNTED=1"
set "MOUNT_METHOD=PART"
set "BCD_PATH=!SYS_DRIVE!\EFI\Microsoft\Boot\BCD"
call :info "EFI system partition is disk !TARGET_DISK! partition !ESP_PART!, mounted as !SYS_DRIVE!"
exit /b 0

:mount_bios
if not defined SYS_VOL goto mount_bios_manual
goto mount_bios_assign

:mount_bios_manual
call :manual_pick_sysvol
if errorlevel 1 exit /b 1
if defined SYS_DRIVE exit /b 0

:mount_bios_assign
call :find_free_letter
if errorlevel 1 (
    call :info "ERROR: no free drive letter is available for the system partition"
    exit /b 1
)
call :dp_begin
call :dp_add "select volume !SYS_VOL!"
call :dp_add "assign letter=!FREE_LETTER!"
call :dp_run
if errorlevel 1 (
    call :info "ERROR: diskpart could not assign a drive letter to the system volume"
    exit /b 1
)
set "SYS_DRIVE=!FREE_LETTER!:"
set "SYS_MOUNTED=1"
set "MOUNT_METHOD=VOL"
set "BCD_PATH=!SYS_DRIVE!\Boot\BCD"
call :info "BIOS system volume !SYS_VOL! mounted as !SYS_DRIVE!"
exit /b 0

rem  Lets the user pick the disk and EFI system partition when detection failed. Refuses a
rem  partition that is not type System.
:manual_pick_esp
echo.
echo The EFI system partition could not be detected automatically.
call :dp_begin
call :dp_add "list disk"
call :dp_run
type "%DP_OUT%"
call :ask_number TARGET_DISK "Enter the number of the disk that contains Windows"
if errorlevel 1 exit /b 1
call :dp_begin
call :dp_add "select disk !TARGET_DISK!"
call :dp_add "list partition"
call :dp_run
type "%DP_OUT%"
call :ask_number ESP_PART "Enter the partition number of the EFI system partition, type System, about 100 to 500 MB"
if errorlevel 1 exit /b 1
findstr /i /r /c:"Partition !ESP_PART! *System" "%DP_OUT%" >nul 2>&1
if errorlevel 1 (
    call :info "ERROR: partition !ESP_PART! on disk !TARGET_DISK! is not of type System, refusing to use it"
    set "ESP_PART="
    exit /b 1
)
exit /b 0

rem  Lets the user pick the BIOS system volume, or W for the Windows drive itself, when
rem  detection failed.
:manual_pick_sysvol
echo.
echo The BIOS system partition could not be detected automatically.
call :dp_begin
call :dp_add "list volume"
call :dp_run
type "%DP_OUT%"
echo.
echo Enter the volume number of the small System Reserved volume that holds
echo bootmgr, or W if the boot files live on the Windows drive itself.
set "MP_IN="
set /p "MP_IN=Volume number, W, or Q to cancel: "
if /i "!MP_IN!"=="Q" exit /b 1
if /i "!MP_IN!"=="W" (
    set "SYS_DRIVE=!WIN_DRIVE!"
    set "SYS_MOUNTED="
    set "MOUNT_METHOD=NONE"
    set "BCD_PATH=!SYS_DRIVE!\Boot\BCD"
    exit /b 0
)
call :is_digits MP_IN
if errorlevel 1 (
    echo Not a valid volume number.
    exit /b 1
)
set "SYS_VOL=!MP_IN!"
exit /b 0

rem  Removes the drive letter this script assigned to the system partition. Never touches a
rem  letter it did not assign.
:unmount_system_partition
if not defined SYS_MOUNTED exit /b 0
if not defined SYS_DRIVE exit /b 0
call :dp_begin
if /i "!MOUNT_METHOD!"=="PART" (
    call :dp_add "select disk !TARGET_DISK!"
    call :dp_add "select partition !ESP_PART!"
) else (
    call :dp_add "select volume !SYS_DRIVE:~0,1!"
)
call :dp_add "remove letter=!SYS_DRIVE:~0,1!"
call :dp_run
call :log "Unmounted !SYS_DRIVE!, diskpart exit code !DP_RC!"
set "SYS_MOUNTED="
set "SYS_DRIVE="
set "BCD_PATH="
exit /b 0

rem ============================================================================
rem  BITLOCKER
rem ============================================================================
:unlock_bitlocker
if not defined HAVE_MANAGEBDE (
    echo manage-bde.exe is not available in this environment.
    exit /b 1
)
echo.
echo BitLocker status of all volumes:
manage-bde -status
echo.
set "UB_IN="
set /p "UB_IN=Drive letter to unlock, for example D: "
if not defined UB_IN exit /b 1
set "UB_LETTER=!UB_IN:~0,1!"
call :is_letter UB_LETTER
if errorlevel 1 (
    echo That is not a valid drive letter.
    exit /b 1
)
echo.
echo Enter the 48 digit recovery password including the dashes.
echo Note: what you type is visible on screen and is not written to the log.
set "UB_PW="
set /p "UB_PW=Recovery password: "
if not defined UB_PW exit /b 1
set "UB_CHK=!UB_PW:-=!"
if not defined UB_CHK (
    echo The recovery password is empty.
    exit /b 1
)
call :digits_only UB_CHK
if errorlevel 1 (
    echo The recovery password may contain digits and dashes only.
    set "UB_PW="
    set "UB_CHK="
    exit /b 1
)
if not "!UB_CHK:~48!"=="" (
    echo The recovery password is longer than 48 digits.
    set "UB_PW="
    exit /b 1
)
if "!UB_CHK:~47!"=="" (
    echo The recovery password is shorter than 48 digits.
    set "UB_PW="
    exit /b 1
)
manage-bde -unlock !UB_LETTER!: -recoverypassword !UB_PW!
set "UB_RC=!errorlevel!"
set "UB_PW="
set "UB_CHK="
call :log "manage-bde unlock of !UB_LETTER!: finished with exit code !UB_RC!"
if not "!UB_RC!"=="0" (
    echo Unlock failed with exit code !UB_RC!. Check the password and the drive letter.
    exit /b 1
)
echo Drive !UB_LETTER!: is now unlocked.
exit /b 0

rem ============================================================================
rem  1  CHKDSK
rem  Exit codes from the chkdsk documentation: 0 no errors, 1 errors found and
rem  fixed, 2 cleanup performed, 3 could not check or could not fix.
rem  /r and /x both include /f, so /f is not repeated.
rem ============================================================================
:run_chkdsk
echo.
echo ===== DISK CHECK AND REPAIR =====
set "CK_FLAGS=/f /x"
if /i "!CK_SURFACE!"=="Y" set "CK_FLAGS=/r /x"
call :info "Running chkdsk !WIN_DRIVE! !CK_FLAGS!. This can take a long time."
chkdsk !WIN_DRIVE! !CK_FLAGS!
set "RC=!errorlevel!"
call :interpret_chkdsk !RC! RES_CHKDSK
exit /b 0

rem  call :interpret_chkdsk CODE RESULT_VAR
:interpret_chkdsk
set "CK_MSG=chkdsk exit code %~1, the volume could not be checked or fixed"
if "%~1"=="0" set "CK_MSG=OK, no errors found"
if "%~1"=="1" set "CK_MSG=OK, errors were found and fixed"
if "%~1"=="2" set "CK_MSG=OK, cleanup was performed"
set "%~2=!CK_MSG!"
call :info "chkdsk result: !CK_MSG!"
exit /b 0

rem ============================================================================
rem  2  DISM AND SFC
rem  The offline image is checked with /CheckHealth and /ScanHealth first. The
rem  DISM reference lists both, with /RestoreHealth, among the /Cleanup-Image
rem  options available for an offline image, and Repair-WindowsImage documents
rem  them with -Path. /RestoreHealth only runs when a check reports corruption.
rem  The image is reported healthy only when BOTH checks complete and print the
rem  English text "No component store corruption detected". Any other result,
rem  including a localized recovery environment, is never reported as healthy:
rem  it either triggers /RestoreHealth or is reported as not verified.
rem  Offline, /RestoreHealth needs a repair source in most cases because Windows
rem  Update is not reachable from the recovery environment.
rem ============================================================================
:run_sfcdism
echo.
echo ===== SYSTEM FILE REPAIR =====
set "RES_DISM=not run"
set "RES_SFC=not run"
set "SCRATCH=!WIN_DRIVE!\_repair_boot_scratch"
rem  The recovery RAM disk is small, so the DISM log goes on the Windows drive.
set "DISM_LOG=%WORKDIR%\dism.log"
if not exist "!WIN_DRIVE!\repair_boot_logs\" md "!WIN_DRIVE!\repair_boot_logs" >nul 2>&1
if exist "!WIN_DRIVE!\repair_boot_logs\" set "DISM_LOG=!WIN_DRIVE!\repair_boot_logs\dism.log"
call :info "DISM log: !DISM_LOG!"
call :info "Starting DISM and SFC for !WIN_DRIVE!. This can take 20 to 60 minutes."

if exist "!TARGET_WINDIR!\WinSxS\pending.xml" (
    echo.
    echo WARNING: A servicing operation is pending on this Windows installation.
    echo SFC and DISM can fail until it is cleared. Microsoft documents reverting
    echo pending actions only for recovering a Windows image that did not boot.
    call :ask_yn "Revert pending servicing actions now?" ANS_REVERT N
    if /i "!ANS_REVERT!"=="Y" (
        dism /image:!WIN_DRIVE!\ /cleanup-image /revertpendingactions /logpath:!DISM_LOG!
        call :info "DISM revertpendingactions exit code !errorlevel!"
    )
)

set "SCRATCH_ARG="
if not exist "!SCRATCH!\" md "!SCRATCH!" >nul 2>&1
if exist "!SCRATCH!\" set "SCRATCH_ARG=/scratchdir:!SCRATCH!"
if not defined SCRATCH_ARG call :info "WARNING: could not create a scratch folder, DISM will use the recovery RAM disk"

set "ST_CHECK="
set "ST_SCAN="
call :dism_check checkhealth ST_CHECK
call :dism_check scanhealth ST_SCAN

set "DO_RESTORE="
set "ALL_HEALTHY="
if "!ST_CHECK!"=="CORRUPT" set "DO_RESTORE=1"
if "!ST_SCAN!"=="CORRUPT" set "DO_RESTORE=1"
if "!ST_CHECK!"=="HEALTHY" if "!ST_SCAN!"=="HEALTHY" set "ALL_HEALTHY=1"
call :info "DISM check results: CheckHealth=!ST_CHECK! ScanHealth=!ST_SCAN!"

if defined DO_RESTORE (
    echo.
    echo DISM reported component store problems. Running RestoreHealth.
    call :dism_restore
) else if defined ALL_HEALTHY (
    set "RES_DISM=OK, CheckHealth and ScanHealth found no component store corruption"
    echo.
    echo DISM found no component store corruption. RestoreHealth is not needed.
) else (
    call :dism_unverified
)

echo.
call :info "Running SFC offline against !WIN_DRIVE!"
sfc /scannow /offbootdir=!WIN_DRIVE!\ /offwindir=!TARGET_WINDIR!
set "RC=!errorlevel!"
call :info "SFC exit code !RC!"
set "RES_SFC=finished, exit code !RC!, details in sfcdetails.txt"
if exist "!TARGET_WINDIR!\Logs\CBS\CBS.log" (
    findstr /c:"[SR]" "!TARGET_WINDIR!\Logs\CBS\CBS.log" > "%WORKDIR%\sfcdetails.txt" 2>nul
    call :info "SFC detail lines saved to %WORKDIR%\sfcdetails.txt"
)

if exist "!SCRATCH!\" rd /s /q "!SCRATCH!" >nul 2>&1
exit /b 0

rem  call :dism_check checkhealth|scanhealth RESULT_VAR
rem  RESULT_VAR becomes HEALTHY, CORRUPT or FAILED, and RESULT_VAR_RC holds the
rem  DISM exit code. The exit code DISM uses for a repairable store is not
rem  documented, so the output text is checked first: "is repairable" and "is not
rem  repairable" mean CORRUPT whatever the exit code. Otherwise exit code 0 plus
rem  "No component store corruption detected" means HEALTHY, exit code 0 with any
rem  other text means CORRUPT, and a non-zero exit code means FAILED. Output goes
rem  to a file because DISM draws a progress bar, so these checks print nothing
rem  until they finish. A pending reboot can make DISM report repairable even
rem  when nothing is wrong, which is why pending actions are offered first.
:dism_check
set "DC_OUT=%WORKDIR%\dism_%~1.txt"
set "DC_STATE=FAILED"
echo.
call :info "Running DISM /%~1 against !WIN_DRIVE!. This can take several minutes and shows no progress."
dism /image:!WIN_DRIVE!\ /cleanup-image /%~1 !SCRATCH_ARG! /logpath:!DISM_LOG! > "!DC_OUT!" 2>&1
set "DC_RC=!errorlevel!"
>>"%LOGFILE%" type "!DC_OUT!"
findstr /v /b /c:"[" "!DC_OUT!"
call :info "DISM /%~1 exit code !DC_RC!"
findstr /c:"component store is repairable" /c:"component store is not repairable" "!DC_OUT!" >nul 2>&1
if not errorlevel 1 set "DC_STATE=CORRUPT"
if "!DC_STATE!"=="FAILED" if "!DC_RC!"=="0" (
    set "DC_STATE=CORRUPT"
    findstr /c:"No component store corruption detected" "!DC_OUT!" >nul 2>&1
    if not errorlevel 1 set "DC_STATE=HEALTHY"
)
set "%~2=!DC_STATE!"
set "%~2_RC=!DC_RC!"
exit /b 0

rem  Runs /RestoreHealth with an optional repair source and sets RES_DISM.
:dism_restore
call :find_dism_source
call :info "Running DISM RestoreHealth against !WIN_DRIVE!"
dism /image:!WIN_DRIVE!\ /cleanup-image /restorehealth !SRC_ARG! !SCRATCH_ARG! /logpath:!DISM_LOG!
set "RC=!errorlevel!"
call :info "DISM RestoreHealth exit code !RC!"
if "!RC!"=="0" (
    set "RES_DISM=OK, RestoreHealth completed"
) else if "!RC!"=="3010" (
    set "RES_DISM=OK, RestoreHealth completed, restart required"
) else (
    set "RES_DISM=FAILED, RestoreHealth exit code !RC!"
    call :dism_hints
)
exit /b 0

rem  Neither check reported corruption, but at least one did not report healthy.
:dism_unverified
echo.
echo DISM could not verify the component store. A check either failed to run or
echo printed text this script does not recognize, for example on a localized
echo recovery environment.
echo   CheckHealth: !ST_CHECK!, exit code !ST_CHECK_RC!
echo   ScanHealth : !ST_SCAN!, exit code !ST_SCAN_RC!
call :dism_hints
call :ask_yn "Run RestoreHealth anyway?" ANS_FORCE N
if /i "!ANS_FORCE!"=="Y" (
    call :dism_restore
) else (
    set "RES_DISM=NOT VERIFIED, the health checks did not complete, nothing was repaired"
)
exit /b 0

rem  Prints the usual causes of a DISM failure.
:dism_hints
echo.
echo DISM did not complete. Common causes:
echo   - 0x800f081f or 0x800f0950: no repair source. Provide Windows media of the
echo     same build and edition, then run this step again.
echo   - Error 50, 87 or a version message: this recovery environment is older than
echo     the installed Windows. Boot from current installation media instead.
echo   - Error 267 or scratch errors: not enough free space on the Windows drive.
echo   - A pending servicing operation: run this step again and revert pending actions.
echo   Full DISM log: !DISM_LOG!
exit /b 0

rem  Looks for install.wim or install.esd on other drives and builds SRC_ARG.
:find_dism_source
set "SRC_ARG="

:find_dism_source_scan
set "SRC_FILE="
set "SRC_KIND="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined SRC_FILE if /i not "%%D:"=="!WIN_DRIVE!" if /i not "%%D:"=="%SystemDrive%" (
        if exist "%%D:\sources\install.wim" (
            set "SRC_FILE=%%D:\sources\install.wim"
            set "SRC_KIND=wim"
        ) else if exist "%%D:\sources\install.esd" (
            set "SRC_FILE=%%D:\sources\install.esd"
            set "SRC_KIND=esd"
        )
    )
)
if defined SRC_FILE goto find_dism_source_found
echo.
echo No Windows installation media was found to use as a DISM repair source.
echo Attach a Windows installation USB or disc of the same version, then press R to
echo rescan, or press Enter to continue without a source.
set "FS_ANS="
set /p "FS_ANS=R to rescan, Enter to continue: "
if /i "!FS_ANS!"=="R" goto find_dism_source_scan
call :info "DISM will run without an explicit repair source"
exit /b 0

:find_dism_source_found
echo.
echo Repair source candidate: !SRC_FILE!
dism /get-wiminfo /wimfile:!SRC_FILE!
echo.
echo The index must match the edition installed on !WIN_DRIVE!, for example Home or Pro.
set "SRC_IDX="
set /p "SRC_IDX=Image index to use as the repair source, or Enter to skip: "
if not defined SRC_IDX (
    call :info "No repair source index chosen"
    exit /b 0
)
call :is_digits SRC_IDX
if errorlevel 1 (
    call :info "Invalid index entered, continuing without a repair source"
    exit /b 0
)
set "SRC_ARG=/source:!SRC_KIND!:!SRC_FILE!:!SRC_IDX! /limitaccess"
call :info "Repair source: !SRC_KIND! !SRC_FILE! index !SRC_IDX!"
exit /b 0

rem ============================================================================
rem  3 and 6  BOOT REPAIR
rem ============================================================================
:run_startup
echo.
echo ===== BOOT REPAIR =====
set "RES_BOOT=not run"
call :info "Boot repair started, fresh BCD forced: !FORCE_FRESH!"

call :resolve_boot_mode
if errorlevel 1 (
    set "RES_BOOT=skipped, boot mode could not be determined"
    exit /b 1
)
call :mount_system_partition
if errorlevel 1 (
    set "RES_BOOT=skipped, system partition not available"
    echo The boot partition could not be located, so nothing was changed.
    if /i "!BOOT_MODE!"=="UEFI" echo If the EFI system partition is gone, recreate it with diskpart first.
    exit /b 1
)

echo.
echo   Windows installation : !WIN_DRIVE!
echo   Boot mode            : !BOOT_MODE!
echo   Boot partition       : !SYS_DRIVE!
echo   BCD store            : !BCD_PATH!
if "!FORCE_FRESH!"=="1" (
    echo   BCD handling         : replace with a freshly generated store
) else (
    echo   BCD handling         : keep a valid store, replace it only if it is damaged or missing
)
echo   A backup copy of the BCD is made first and restored if the rebuild fails.
if /i "!BOOT_MODE!"=="BIOS" (
    echo   The MBR boot code and the volume boot sector will be rewritten. This
    echo   replaces any other boot loader installed in the MBR, such as GRUB.
)
echo.
call :ask_yn "Proceed with boot repair on this disk?" ANS_BOOT N
if /i not "!ANS_BOOT!"=="Y" (
    set "RES_BOOT=cancelled by user"
    exit /b 0
)

if defined HAVE_BOOTREC (
    echo.
    call :info "Windows installations known to the boot manager, from bootrec /scanos:"
    bootrec /scanos
)

call :bcd_backup
if errorlevel 1 (
    set "RES_BOOT=aborted, the BCD backup failed"
    exit /b 1
)
call :check_boot_partition
call :rebuild_bcd
if errorlevel 1 (
    set "RES_BOOT=failed, bcdboot could not rebuild the boot files"
    call :bootrec_fallback
    exit /b 1
)
call :write_boot_code
call :verify_boot
if errorlevel 1 (
    set "RES_BOOT=boot files written but the BCD has no Windows loader entry, check the log"
    exit /b 1
)
set "RES_BOOT=OK, boot files rebuilt on !SYS_DRIVE! for !BOOT_MODE! boot"
call :info "Boot repair finished: !RES_BOOT!"
echo.
echo NOTE: If BitLocker is on, the next start may ask for the recovery key because
echo the boot files changed. Have the key ready.
if /i "!BOOT_MODE!"=="BIOS" (
    echo NOTE: On BIOS systems the partition holding bootmgr must be marked active.
    echo If the PC still does not boot, mark it active with diskpart.
)
exit /b 0

rem  Settles BOOT_MODE, asking when the disk layout could not be read, and warns when the
rem  firmware mode differs. Returns 1 when cancelled.
:resolve_boot_mode
if /i "!BOOT_MODE!"=="UEFI" goto rbm_check
if /i "!BOOT_MODE!"=="BIOS" goto rbm_check
echo.
echo The partition style of the Windows disk could not be determined.
echo   U  the disk is GPT and the PC boots with UEFI
echo   B  the disk is MBR and the PC boots with legacy BIOS
set "RBM_IN="
set /p "RBM_IN=Choose U, B or Q to cancel: "
if /i "!RBM_IN!"=="U" set "BOOT_MODE=UEFI"
if /i "!RBM_IN!"=="B" set "BOOT_MODE=BIOS"
if /i not "!BOOT_MODE!"=="UEFI" if /i not "!BOOT_MODE!"=="BIOS" exit /b 1

:rbm_check
if /i "!FW_MODE!"=="Unknown" exit /b 0
if /i "!FW_MODE!"=="!BOOT_MODE!" exit /b 0
echo.
echo WARNING: This environment started in !FW_MODE! mode but the Windows disk needs !BOOT_MODE! boot.
echo The boot files will be written correctly, but the firmware boot entry can only
echo be created when the recovery media is started in !BOOT_MODE! mode.
call :info "Firmware mismatch: environment is !FW_MODE!, disk needs !BOOT_MODE!"
exit /b 0

rem  Copies the current BCD to a unique .bak file. Returns 1 when the copy fails.
:bcd_backup
set "BCD_BACKUP="
if not exist "!BCD_PATH!" (
    call :info "No existing BCD at !BCD_PATH!, nothing to back up"
    exit /b 0
)
call :unique_name "!BCD_PATH!.bak" BCD_BACKUP
if errorlevel 1 (
    set "BCD_BACKUP="
    call :info "ERROR: no free backup file name for the BCD"
    exit /b 1
)
copy /y "!BCD_PATH!" "!BCD_BACKUP!" >nul 2>&1
if errorlevel 1 (
    call :info "ERROR: could not back up the BCD to !BCD_BACKUP!"
    exit /b 1
)
call :info "BCD backed up to !BCD_BACKUP!"
exit /b 0

rem  Runs chkdsk on a separate boot partition and offers an EFI reformat when it cannot be repaired.
:check_boot_partition
if /i "!SYS_DRIVE!"=="!WIN_DRIVE!" exit /b 0
call :info "Running chkdsk on the boot partition !SYS_DRIVE!"
chkdsk !SYS_DRIVE! /f
set "RC=!errorlevel!"
call :interpret_chkdsk !RC! RES_CHKDSK_BOOT
if not "!RC!"=="3" exit /b 0
if /i not "!BOOT_MODE!"=="UEFI" exit /b 0
if /i not "!MOUNT_METHOD!"=="PART" exit /b 0
call :offer_format_esp
exit /b 0

rem  Reformats the EFI system partition as FAT32, only after the user types FORMAT.
:offer_format_esp
echo.
echo The EFI system partition has errors that chkdsk could not fix.
echo It can be reformatted as FAT32 and the boot files rebuilt. This erases
echo everything on that partition, including boot files of other operating
echo systems and vendor recovery tools, but not Windows itself.
call :ask_typed "Type FORMAT to reformat the EFI system partition, or press Enter to skip" FORMAT
if errorlevel 1 (
    call :info "EFI system partition reformat skipped by user"
    exit /b 0
)
call :dp_begin
call :dp_add "select disk !TARGET_DISK!"
call :dp_add "select partition !ESP_PART!"
call :dp_add "format fs=fat32 quick label=System override"
call :dp_run
if errorlevel 1 (
    call :info "ERROR: diskpart could not format the EFI system partition"
    exit /b 0
)
call :info "EFI system partition reformatted as FAT32"
exit /b 0

rem  Rebuilds boot files with bcdboot. The BCD is replaced only when forced, missing or
rem  unreadable, and restored from the backup when bcdboot fails.
:rebuild_bcd
set "NEED_FRESH="
set "BCD_MOVED="
if "!FORCE_FRESH!"=="1" set "NEED_FRESH=1"
if not exist "!BCD_PATH!" set "NEED_FRESH=1"
if exist "!BCD_PATH!" (
    bcdedit /store "!BCD_PATH!" /enum {bootmgr} >nul 2>&1
    if errorlevel 1 (
        call :info "The existing BCD store is not readable and will be replaced"
        set "NEED_FRESH=1"
    )
)
if defined NEED_FRESH if exist "!BCD_PATH!" (
    call :unique_name "!BCD_PATH!.replaced" BCD_MOVED
    attrib -s -h -r "!BCD_PATH!" >nul 2>&1
    for %%F in ("!BCD_MOVED!") do ren "!BCD_PATH!" "%%~nxF"
    if exist "!BCD_PATH!" (
        call :info "ERROR: could not move the old BCD aside"
        set "BCD_MOVED="
        exit /b 1
    )
    call :info "Old BCD moved to !BCD_MOVED!"
)

set "BB_FW=UEFI"
if /i "!BOOT_MODE!"=="BIOS" set "BB_FW=BIOS"
call :info "Running bcdboot !TARGET_WINDIR! /s !SYS_DRIVE! /f !BB_FW!"
bcdboot "!TARGET_WINDIR!" /s !SYS_DRIVE! /f !BB_FW! /v
set "RC=!errorlevel!"
call :info "bcdboot exit code !RC!"
set "BB_OK="
if "!BB_FW!"=="UEFI" if exist "!SYS_DRIVE!\EFI\Microsoft\Boot\bootmgfw.efi" if exist "!BCD_PATH!" set "BB_OK=1"
if "!BB_FW!"=="BIOS" if exist "!SYS_DRIVE!\bootmgr" if exist "!BCD_PATH!" set "BB_OK=1"
if "!RC!"=="0" if defined BB_OK exit /b 0

call :info "ERROR: bcdboot did not complete successfully"
if not defined BCD_BACKUP exit /b 1
if not exist "!BCD_BACKUP!" exit /b 1
if exist "!BCD_PATH!" (
    attrib -s -h -r "!BCD_PATH!" >nul 2>&1
    del /f /q "!BCD_PATH!" >nul 2>&1
    if exist "!BCD_PATH!" call :info "WARNING: the damaged BCD could not be deleted, overwriting it"
)
copy /y "!BCD_BACKUP!" "!BCD_PATH!" >nul 2>&1
if errorlevel 1 (
    call :info "ERROR: the BCD could not be restored automatically, copy !BCD_BACKUP! over !BCD_PATH! by hand"
    exit /b 1
)
attrib +s +h "!BCD_PATH!" >nul 2>&1
call :info "The previous BCD store was restored from !BCD_BACKUP!"
exit /b 1

rem  BIOS only. UEFI systems have no MBR boot code, and bootrec /fixboot fails
rem  with Access is denied on GPT disks.
:write_boot_code
if /i not "!BOOT_MODE!"=="BIOS" exit /b 0
if defined HAVE_BOOTSECT (
    call :info "Running bootsect /nt60 !SYS_DRIVE! /force to write the volume boot sector"
    bootsect /nt60 !SYS_DRIVE! /force
    set "RC1=!errorlevel!"
    call :info "Running bootsect /nt60 !SYS_DRIVE! /force /mbr to write the master boot record"
    bootsect /nt60 !SYS_DRIVE! /force /mbr
    set "RC2=!errorlevel!"
    call :info "bootsect exit codes: boot sector !RC1!, MBR !RC2!"
    if "!RC1!"=="0" if "!RC2!"=="0" exit /b 0
    call :info "bootsect reported a problem, trying bootrec as well"
)
if defined HAVE_BOOTREC (
    call :info "Running bootrec /fixmbr and /fixboot"
    bootrec /fixmbr
    bootrec /fixboot
    exit /b 0
)
call :info "WARNING: neither bootsect nor bootrec is available, MBR boot code was not written"
exit /b 0

rem  Lists the Windows loader entries. Returns 1 when the BCD is unreadable or has no winload entry.
:verify_boot
bcdedit /store "!BCD_PATH!" /enum {bootmgr} >nul 2>&1
if errorlevel 1 exit /b 1
bcdedit /store "!BCD_PATH!" /enum osloader > "%WORKDIR%\bcd_osloader.txt" 2>&1
echo.
echo Windows loader entries now in the BCD:
type "%WORKDIR%\bcd_osloader.txt"
>>"%LOGFILE%" type "%WORKDIR%\bcd_osloader.txt"
findstr /i /c:"winload" "%WORKDIR%\bcd_osloader.txt" >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

rem  bootrec /rebuildbcd asks Yes, No or All for each installation it finds, so
rem  it must run with a visible console and is only offered as a last resort.
:bootrec_fallback
if not defined HAVE_BOOTREC exit /b 0
echo.
echo bcdboot failed. As a last resort bootrec /rebuildbcd can be run. It is
echo interactive: answer Y or A when it asks to add the Windows installation.
call :ask_yn "Run bootrec /rebuildbcd now?" ANS_REBUILD N
if /i not "!ANS_REBUILD!"=="Y" exit /b 0
bootrec /rebuildbcd
call :info "bootrec /rebuildbcd exit code !errorlevel!"
exit /b 0

rem ============================================================================
rem  4  MEMORY DIAGNOSTIC
rem  call :run_memdiag Y   skips the confirmation prompt
rem ============================================================================
:run_memdiag
echo.
echo ===== MEMORY DIAGNOSTIC =====
set "RES_MEM=not run"
call :resolve_boot_mode
if errorlevel 1 (
    set "RES_MEM=skipped, boot mode could not be determined"
    exit /b 1
)
call :mount_system_partition
if errorlevel 1 (
    set "RES_MEM=skipped, system partition not available"
    exit /b 1
)
if not exist "!BCD_PATH!" (
    set "RES_MEM=skipped, BCD not found at !BCD_PATH!"
    call :info "!RES_MEM!"
    exit /b 1
)
bcdedit /store "!BCD_PATH!" /enum {memdiag} >nul 2>&1
if errorlevel 1 (
    set "RES_MEM=skipped, no memory diagnostic entry in the BCD, run boot repair first"
    call :info "!RES_MEM!"
    exit /b 1
)
if /i not "%~1"=="Y" (
    echo.
    echo The next start of this PC will run Windows Memory Diagnostic before Windows.
    echo The standard test takes 10 to 30 minutes and can be cancelled with Esc.
    call :ask_yn "Schedule the memory diagnostic for the next boot?" ANS_MEM N
    if /i not "!ANS_MEM!"=="Y" (
        set "RES_MEM=cancelled by user"
        exit /b 0
    )
)
bcdedit /store "!BCD_PATH!" /bootsequence {memdiag}
set "RC=!errorlevel!"
if not "!RC!"=="0" (
    set "RES_MEM=failed, bcdedit exit code !RC!"
    call :info "!RES_MEM!"
    exit /b 1
)
set "RES_MEM=scheduled for the next boot only, results appear in Event Viewer afterwards"
call :info "Memory diagnostic scheduled in !BCD_PATH!"
exit /b 0

rem ============================================================================
rem  CLEANUP AND LOG COPY
rem ============================================================================
:cleanup
call :save_logs
call :unmount_system_partition
exit /b 0

rem  Copies the working logs to the Windows drive so they outlive the recovery RAM disk.
:save_logs
set "LOG_SAVED_TO="
if not defined WIN_DRIVE exit /b 0
set "LOG_ROOT=!WIN_DRIVE!\repair_boot_logs"
if not exist "!LOG_ROOT!\" md "!LOG_ROOT!" >nul 2>&1
if not exist "!LOG_ROOT!\" (
    call :info "WARNING: could not create !LOG_ROOT!, the logs stay on the RAM disk only"
    exit /b 0
)
set "LOG_RUN="
call :unique_name "!LOG_ROOT!\run" LOG_RUN
if not defined LOG_RUN (
    call :info "WARNING: no free log folder name under !LOG_ROOT!"
    exit /b 0
)
md "!LOG_RUN!" >nul 2>&1
if not exist "!LOG_RUN!\" (
    call :info "WARNING: could not create !LOG_RUN!, the logs stay on the RAM disk only"
    exit /b 0
)
copy /y "%WORKDIR%\*.log" "!LOG_RUN!\" >nul 2>&1
if errorlevel 1 (
    call :info "WARNING: could not copy the log files to !LOG_RUN!"
    exit /b 0
)
copy /y "%WORKDIR%\*.txt" "!LOG_RUN!\" >nul 2>&1
if errorlevel 1 call :info "WARNING: could not copy the diskpart and DISM text files to !LOG_RUN!"
set "LOG_SAVED_TO=!LOG_RUN!"
exit /b 0

rem ============================================================================
rem  EXIT POINTS, reached with goto and never with call
rem  They sit last so the endlocal in :finish is the final statement in the file.
rem ============================================================================
:finish
echo.
echo ==============================================================
echo   Summary of what actually ran
echo ==============================================================
echo   Disk check    : !RES_CHKDSK!
echo   DISM          : !RES_DISM!
echo   SFC           : !RES_SFC!
echo   Boot repair   : !RES_BOOT!
echo   Memory test   : !RES_MEM!
echo.
call :cleanup
if defined LOG_SAVED_TO echo   Logs saved to: !LOG_SAVED_TO!
echo   Working log  : %LOGFILE%
echo.
echo Close this window and choose Continue to start Windows, or type
echo wpeutil reboot to restart now.
endlocal
exit /b 0

:usage
echo repair_boot.cmd v3.1 - Windows Recovery Environment repair helper
echo.
echo Usage: run it from Windows RE or Windows PE command prompt, no arguments.
echo   repair_boot.cmd
echo.
echo It offers chkdsk, DISM with SFC, boot file repair with bcdboot, and a
echo memory diagnostic. Every destructive step asks for confirmation first.
exit /b 0
