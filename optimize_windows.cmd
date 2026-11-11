@echo off
rem ============================================================================
rem optimize_windows.cmd - Windows performance tweaks with backup, logging, undo
rem
rem Usage:   optimize_windows.cmd [options]
rem   (no options)      Apply the recommended tweaks.
rem   /undo             Restore every value recorded by earlier runs.
rem   /dryrun           Show what would change; write nothing.
rem   /norestorepoint   Skip the system restore point (built-in /undo still works).
rem   /nopause          Do not wait for a key press at the end.
rem   /noelevate        Fail instead of asking for administrator rights (UAC).
rem   /mouse            Also disable pointer acceleration.
rem   /cpu              Also set the minimum processor state to 100 percent on AC.
rem   /sysmain          Also disable SysMain (Superfetch) on SSD systems.
rem   /tdr              Also raise the GPU timeout (TDR) delays.
rem   /all              Same as /mouse /cpu /sysmain /tdr.
rem   /help             Show this help.
rem
rem Exit codes: 0 ok, 1 finished with errors, 2 bad options, 3 environment not
rem supported or another instance is running, 4 not elevated, 5 no restore point.
rem
rem The tweak logic is PowerShell that sits below the payload marker at the end of
rem this file. cmd.exe stops reading at "exit /b" and never parses it.
rem ============================================================================
setlocal EnableExtensions DisableDelayedExpansion

set "OPTWIN_PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "OPTWIN_PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%OPTWIN_PSEXE%" (
    echo ERROR: Windows PowerShell was not found at "%OPTWIN_PSEXE%".
    exit /b 3
)

set "OPTWIN_SELF=%~f0"
set "OPTWIN_ARGS=%*"
"%OPTWIN_PSEXE%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $t=[IO.File]::ReadAllText($env:OPTWIN_SELF); $m='#'+'#PAYLOAD-BEGIN##'; $i=$t.LastIndexOf($m); if($i -lt 0){throw 'payload marker not found'}; & ([scriptblock]::Create($t.Substring($i+$m.Length)))"
set "OPTWIN_RC=%ERRORLEVEL%"
exit /b %OPTWIN_RC%
##PAYLOAD-BEGIN##
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Constants and script state
# ----------------------------------------------------------------------------
$script:Version = '2.0.0'
$script:AppDir = Join-Path -Path $env:ProgramData -ChildPath 'WindowsPerformanceTweaks'
$script:BaselineFile = Join-Path -Path $script:AppDir -ChildPath 'baseline.json'
$script:RestorePointName = 'Before Windows performance tweaks'
$script:PowerCfg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe'

$script:GuidSubUsb = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:GuidUsbSelectiveSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$script:GuidSubProcessor = '54533251-82be-4824-96c1-47b60b740d00'
$script:GuidProcThrottleMin = '893dee8e-2bef-41e0-89c6-b55d0929964c'

$script:LogFile = $null
$script:Results = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:Baseline = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:PowerSchemesToApply = @{}
$script:NeedsRestart = $false
$script:NeedsSignOut = $false
$script:SkipPause = $false
$script:OsBuild = 0
$script:RamGb = 0.0
$script:IsPortable = $false
$script:Mutex = $null
$script:MutexHeld = $false
$script:ExitCode = 1
$script:Opt = $null

# ----------------------------------------------------------------------------
# Logging and result tracking
# ----------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'SKIP', 'WARN', 'ERROR', 'DRY')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'DRY' { 'Cyan' }
        'SKIP' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host ('[{0,-5}] {1}' -f $Level, $Message) -ForegroundColor $color
    if ($null -ne $script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value ('{0} [{1,-5}] {2}' -f $stamp, $Level, $Message) -Encoding UTF8
        }
        catch {
            $script:LogFile = $null
            Write-Host ('[WARN ] Writing to the log file failed and file logging was turned off: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Add-Result {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('Applied', 'Skipped', 'Failed', 'DryRun', 'Restored')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{ Id = $Id; Description = $Description; Status = $Status; Detail = $Detail })
    $level = switch ($Status) {
        'Applied' { 'OK' }
        'Restored' { 'OK' }
        'Skipped' { 'SKIP' }
        'DryRun' { 'DRY' }
        default { 'ERROR' }
    }
    $text = if ($Detail) { '{0} - {1}' -f $Description, $Detail } else { $Description }
    Write-Log -Level $level -Message ('{0}: {1}' -f $Status.ToUpperInvariant(), $text)
}

# ----------------------------------------------------------------------------
# Option parsing
# ----------------------------------------------------------------------------
function ConvertFrom-ArgumentString {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $opt = @{
        Undo = $false; DryRun = $false; NoRestorePoint = $false; NoPause = $false; NoElevate = $false
        Help = $false; Mouse = $false; Tdr = $false; SysMain = $false; Cpu = $false; Unknown = @()
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $opt }
    foreach ($token in ($Text -split '\s+')) {
        if ([string]::IsNullOrEmpty($token)) { continue }
        switch ($token.TrimStart([char[]]'/-').ToLowerInvariant()) {
            'undo' { $opt['Undo'] = $true }
            'dryrun' { $opt['DryRun'] = $true }
            'norestorepoint' { $opt['NoRestorePoint'] = $true }
            'nopause' { $opt['NoPause'] = $true }
            'noelevate' { $opt['NoElevate'] = $true }
            'mouse' { $opt['Mouse'] = $true }
            'cpu' { $opt['Cpu'] = $true }
            'sysmain' { $opt['SysMain'] = $true }
            'tdr' { $opt['Tdr'] = $true }
            'all' { $opt['Mouse'] = $true; $opt['Cpu'] = $true; $opt['SysMain'] = $true; $opt['Tdr'] = $true }
            { $_ -in @('help', 'h', '?') } { $opt['Help'] = $true }
            default { $opt['Unknown'] += $token }
        }
    }
    return $opt
}

function Show-Usage {
    [CmdletBinding()]
    param()
    $lines = @(
        ('Windows performance tweaks {0}' -f $script:Version),
        '',
        'Usage: optimize_windows.cmd [options]',
        '  (no options)      Apply the recommended tweaks.',
        '  /undo             Restore every value recorded by earlier runs.',
        '  /dryrun           Show what would change; write nothing.',
        '  /norestorepoint   Skip the system restore point (built-in /undo still works).',
        '  /nopause          Do not wait for a key press at the end.',
        '  /noelevate        Fail instead of asking for administrator rights.',
        '  /mouse            Also disable pointer acceleration.',
        '  /cpu              Also set the minimum processor state to 100 percent on AC.',
        '  /sysmain          Also disable SysMain (Superfetch) on SSD systems.',
        '  /tdr              Also raise the GPU timeout (TDR) delays.',
        '  /all              Same as /mouse /cpu /sysmain /tdr.',
        '  /help             Show this help.'
    )
    foreach ($line in $lines) { Write-Host $line }
}

# ----------------------------------------------------------------------------
# Environment helpers
# ----------------------------------------------------------------------------
function Test-Elevated {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join [Environment]::NewLine) }
}

function Test-PortableComputer {
    [CmdletBinding()]
    param()
    $portableTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktopTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 35, 36)
    $types = @()
    try {
        $types = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    }
    catch {
        Write-Log -Level WARN -Message ('Could not read the chassis type: {0}' -f $_.Exception.Message)
    }
    foreach ($type in $types) {
        if ($portableTypes -contains [int]$type) { return $true }
    }
    foreach ($type in $types) {
        if ($desktopTypes -contains [int]$type) { return $false }
    }
    $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    return ($battery.Count -gt 0)
}

function Get-SystemDriveMediaType {
    [CmdletBinding()]
    param()
    $letter = $env:SystemDrive.TrimEnd(':')
    try {
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $physical = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        if ($null -eq $physical) { return 'Unknown' }
        return [string]$physical.MediaType
    }
    catch {
        Write-Log -Level WARN -Message ('Could not determine the system drive media type: {0}' -f $_.Exception.Message)
        return 'Unknown'
    }
}

function Get-TargetUserSid {
    [CmdletBinding()]
    param()
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if (-not [string]::IsNullOrEmpty($userName)) {
            $account = New-Object -TypeName Security.Principal.NTAccount -ArgumentList $userName
            $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
            $base = Open-RegistryBase -Hive 'Users'
            try {
                $root = $base.OpenSubKey($sid, $false)
                if ($null -ne $root) {
                    $root.Close()
                    return $sid
                }
            }
            finally {
                $base.Close()
            }
        }
    }
    catch {
        Write-Log -Level WARN -Message ('Could not resolve the signed-in user, using the current account: {0}' -f $_.Exception.Message)
    }
    return $current
}

# ----------------------------------------------------------------------------
# Registry primitives (always the 64-bit view, independent of host bitness)
# ----------------------------------------------------------------------------
function Open-RegistryBase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('LocalMachine', 'Users')][string]$Hive)
    $hiveEnum = if ($Hive -eq 'Users') { [Microsoft.Win32.RegistryHive]::Users } else { [Microsoft.Win32.RegistryHive]::LocalMachine }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, [Microsoft.Win32.RegistryView]::Registry64)
}

function Assert-HiveRoot {
    [CmdletBinding()]
    param([string]$Hive, [string]$SubKey)
    if ($Hive -ne 'Users') { return }
    $sid = $SubKey.Split('\')[0]
    $base = Open-RegistryBase -Hive 'Users'
    try {
        $root = $base.OpenSubKey($sid, $false)
        if ($null -eq $root) { throw ('The user registry hive for {0} is not loaded.' -f $sid) }
        $root.Close()
    }
    finally {
        $base.Close()
    }
}

function Get-RegistryValueState {
    [CmdletBinding()]
    param([string]$Hive, [string]$SubKey, [string]$Name)
    $base = Open-RegistryBase -Hive $Hive
    try {
        $key = $base.OpenSubKey($SubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ KeyExists = $false; Existed = $false; Kind = ''; Value = $null }
        }
        try {
            if (@($key.GetValueNames()) -notcontains $Name) {
                return [pscustomobject]@{ KeyExists = $true; Existed = $false; Kind = ''; Value = $null }
            }
            $kind = $key.GetValueKind($Name)
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; Existed = $true; Kind = $kind.ToString(); Value = $value }
        }
        finally {
            $key.Close()
        }
    }
    finally {
        $base.Close()
    }
}

function Set-RegistryValueRaw {
    [CmdletBinding()]
    param(
        [string]$Hive,
        [string]$SubKey,
        [string]$Name,
        [Microsoft.Win32.RegistryValueKind]$Kind,
        $Value
    )
    Assert-HiveRoot -Hive $Hive -SubKey $SubKey
    $base = Open-RegistryBase -Hive $Hive
    try {
        $key = $base.CreateSubKey($SubKey)
        try {
            $key.SetValue($Name, $Value, $Kind)
        }
        finally {
            $key.Close()
        }
    }
    finally {
        $base.Close()
    }
}

function Remove-RegistryValueRaw {
    [CmdletBinding()]
    param([string]$Hive, [string]$SubKey, [string]$Name)
    Assert-HiveRoot -Hive $Hive -SubKey $SubKey
    $base = Open-RegistryBase -Hive $Hive
    try {
        $key = $base.OpenSubKey($SubKey, $true)
        if ($null -ne $key) {
            try {
                $key.DeleteValue($Name, $false)
            }
            finally {
                $key.Close()
            }
        }
    }
    finally {
        $base.Close()
    }
}

function ConvertTo-DWordInt32 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Value)
    if ($Value -lt [int]::MinValue -or $Value -gt [uint32]::MaxValue) {
        throw ('Value {0} is outside the DWORD range.' -f $Value)
    }
    if ($Value -gt [int]::MaxValue) { return [int]($Value - 4294967296) }
    return [int]$Value
}

# ----------------------------------------------------------------------------
# Baseline (original values) used by /undo
# ----------------------------------------------------------------------------
function Import-Baseline {
    [CmdletBinding()]
    param()
    $script:Baseline = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $script:BaselineFile)) { return }
    try {
        $document = [IO.File]::ReadAllText($script:BaselineFile) | ConvertFrom-Json
        foreach ($item in @($document.Items)) { $script:Baseline.Add($item) }
    }
    catch {
        throw ('The baseline file {0} is unreadable ({1}). It was left untouched; repair or move it before running again.' -f $script:BaselineFile, $_.Exception.Message)
    }
}

function Save-Baseline {
    [CmdletBinding()]
    param()
    $document = [ordered]@{
        Version  = 1
        Updated  = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME
        Items    = @($script:Baseline)
    }
    $json = ConvertTo-Json -InputObject $document -Depth 6
    $temporary = $script:BaselineFile + '.tmp'
    [IO.File]::WriteAllText($temporary, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    Move-Item -LiteralPath $temporary -Destination $script:BaselineFile -Force
}

function Add-Baseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    foreach ($existing in $script:Baseline) {
        if ($existing.Key -eq $Entry['Key']) { return }
    }
    $script:Baseline.Add([pscustomobject]$Entry)
    Save-Baseline
}

# ----------------------------------------------------------------------------
# Tweak primitives
# ----------------------------------------------------------------------------
function Set-TweakRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('LocalMachine', 'Users')][string]$Hive,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind,
        [Parameter(Mandatory)]$Value,
        [switch]$RequireKey
    )
    try {
        $desired = if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { ConvertTo-DWordInt32 -Value $Value } else { [string]$Value }
        $current = Get-RegistryValueState -Hive $Hive -SubKey $SubKey -Name $Name
        if ($RequireKey -and -not $current.KeyExists) {
            Add-Result -Id $Id -Description $Description -Status Skipped -Detail 'registry key is not present on this system'
            return
        }
        if ($current.Existed -and $current.Kind -eq $Kind.ToString() -and ([string]$current.Value) -eq ([string]$desired)) {
            Add-Result -Id $Id -Description $Description -Status Skipped -Detail 'already set'
            return
        }
        if ($script:Opt['DryRun']) {
            Add-Result -Id $Id -Description $Description -Status DryRun -Detail ('would set {0} to {1}' -f $Name, $desired)
            return
        }
        Add-Baseline -Entry @{
            Key = ('Reg|{0}|{1}|{2}' -f $Hive, $SubKey, $Name); Type = 'Registry'; Hive = $Hive; SubKey = $SubKey
            Name = $Name; Existed = [bool]$current.Existed; Kind = [string]$current.Kind; Value = $current.Value
        }
        Set-RegistryValueRaw -Hive $Hive -SubKey $SubKey -Name $Name -Kind $Kind -Value $desired
        $after = Get-RegistryValueState -Hive $Hive -SubKey $SubKey -Name $Name
        if (-not $after.Existed -or ([string]$after.Value) -ne ([string]$desired)) {
            throw ('read-back after writing returned {0}' -f $after.Value)
        }
        Add-Result -Id $Id -Description $Description -Status Applied -Detail ('{0} = {1}' -f $Name, $desired)
    }
    catch {
        Add-Result -Id $Id -Description $Description -Status Failed -Detail $_.Exception.Message
    }
}

function Get-ActiveSchemeGuid {
    [CmdletBinding()]
    param()
    $result = Invoke-Native -FilePath $script:PowerCfg -Arguments @('/getactivescheme')
    if ($result.ExitCode -ne 0) {
        throw ('powercfg /getactivescheme failed (exit {0}): {1}' -f $result.ExitCode, $result.Output)
    }
    $match = [regex]::Match($result.Output, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw ('Could not find the active power scheme GUID in: {0}' -f $result.Output) }
    return $match.Value.ToLowerInvariant()
}

function Get-PowerSettingIndex {
    [CmdletBinding()]
    param([string]$Scheme, [string]$SubGroup, [string]$Setting)
    $result = Invoke-Native -FilePath $script:PowerCfg -Arguments @('/query', $Scheme, $SubGroup, $Setting)
    if ($result.ExitCode -ne 0) { return $null }
    # The last two hex numbers are the current AC and DC indexes; this avoids parsing localized labels.
    $hex = @([regex]::Matches($result.Output, '0x[0-9a-fA-F]+'))
    if ($hex.Count -lt 2) { return $null }
    return [pscustomobject]@{
        AC = [Convert]::ToInt32($hex[$hex.Count - 2].Value.Substring(2), 16)
        DC = [Convert]::ToInt32($hex[$hex.Count - 1].Value.Substring(2), 16)
    }
}

function Set-PowerValue {
    [CmdletBinding()]
    param(
        [string]$Scheme,
        [string]$SubGroup,
        [string]$Setting,
        [Parameter(Mandatory)][ValidateSet('AC', 'DC')][string]$Mode,
        [int]$Value
    )
    $verb = if ($Mode -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $result = Invoke-Native -FilePath $script:PowerCfg -Arguments @($verb, $Scheme, $SubGroup, $Setting, [string]$Value)
    if ($result.ExitCode -ne 0) {
        throw ('powercfg {0} failed (exit {1}): {2}' -f $verb, $result.ExitCode, $result.Output.Trim())
    }
}

function Set-TweakPower {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$SubGroup,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string[]]$Modes,
        [Parameter(Mandatory)][int]$Value
    )
    try {
        $scheme = Get-ActiveSchemeGuid
        $current = Get-PowerSettingIndex -Scheme $scheme -SubGroup $SubGroup -Setting $Setting
        if ($null -eq $current) {
            Add-Result -Id $Id -Description $Description -Status Skipped -Detail 'this power setting is not exposed on this system'
            return
        }
        foreach ($mode in $Modes) {
            $resultId = '{0}-{1}' -f $Id, $mode.ToLowerInvariant()
            $label = '{0} ({1})' -f $Description, $mode
            $currentValue = [int]$current.$mode
            if ($currentValue -eq $Value) {
                Add-Result -Id $resultId -Description $label -Status Skipped -Detail 'already set'
                continue
            }
            if ($script:Opt['DryRun']) {
                Add-Result -Id $resultId -Description $label -Status DryRun -Detail ('would change {0} to {1}' -f $currentValue, $Value)
                continue
            }
            Add-Baseline -Entry @{
                Key = ('Power|{0}|{1}|{2}|{3}' -f $scheme, $SubGroup, $Setting, $mode); Type = 'Power'; Scheme = $scheme
                SubGroup = $SubGroup; Setting = $Setting; Mode = $mode; Value = $currentValue
            }
            Set-PowerValue -Scheme $scheme -SubGroup $SubGroup -Setting $Setting -Mode $mode -Value $Value
            $script:PowerSchemesToApply[$scheme] = $true
            $check = Get-PowerSettingIndex -Scheme $scheme -SubGroup $SubGroup -Setting $Setting
            if ($null -eq $check -or [int]$check.$mode -ne $Value) {
                throw ('read-back of the {0} value did not match' -f $mode)
            }
            Add-Result -Id $resultId -Description $label -Status Applied -Detail ('{0} -> {1}' -f $currentValue, $Value)
        }
    }
    catch {
        Add-Result -Id $Id -Description $Description -Status Failed -Detail $_.Exception.Message
    }
}

function Invoke-PowerApply {
    [CmdletBinding()]
    param()
    if ($script:PowerSchemesToApply.Count -eq 0) { return }
    $active = Get-ActiveSchemeGuid
    foreach ($scheme in @($script:PowerSchemesToApply.Keys)) {
        if ($scheme -ne $active) {
            Write-Log -Level INFO -Message ('Power scheme {0} is not active; its values apply when it is selected.' -f $scheme)
            continue
        }
        $result = Invoke-Native -FilePath $script:PowerCfg -Arguments @('/setactive', $scheme)
        if ($result.ExitCode -ne 0) {
            Add-Result -Id 'power-apply' -Description 'Re-activate the power scheme' -Status Failed -Detail ('exit {0}: {1}' -f $result.ExitCode, $result.Output.Trim())
        }
        else {
            Write-Log -Level INFO -Message 'Power scheme re-activated so the new values take effect.'
        }
    }
    $script:PowerSchemesToApply = @{}
}

function Set-ServiceStartMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('auto', 'delayed-auto', 'demand', 'disabled')][string]$Mode
    )
    $sc = Join-Path -Path $env:SystemRoot -ChildPath 'System32\sc.exe'
    $result = Invoke-Native -FilePath $sc -Arguments @('config', $Name, 'start=', $Mode)
    if ($result.ExitCode -ne 0) {
        throw ('sc.exe config failed (exit {0}): {1}' -f $result.ExitCode, $result.Output.Trim())
    }
}

# ----------------------------------------------------------------------------
# System restore point
# ----------------------------------------------------------------------------
function Get-LatestRestoreSequence {
    [CmdletBinding()]
    param()
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        if ($points.Count -eq 0) { return 0 }
        return [int](($points | Measure-Object -Property SequenceNumber -Maximum).Maximum)
    }
    catch {
        return 0
    }
}

function New-TweakRestorePoint {
    [CmdletBinding()]
    param()
    if ($null -eq (Get-Command -Name Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        throw 'Checkpoint-Computer is not available on this system.'
    }
    $subKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $original = Get-RegistryValueState -Hive 'LocalMachine' -SubKey $subKey -Name $name
    $before = Get-LatestRestoreSequence
    try {
        # Windows silently skips a new restore point when one exists from the last 24 hours unless this is 0.
        Set-RegistryValueRaw -Hive 'LocalMachine' -SubKey $subKey -Name $name -Kind DWord -Value 0
        Checkpoint-Computer -Description $script:RestorePointName -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop | Out-Null
    }
    finally {
        if ($original.Existed) {
            Set-RegistryValueRaw -Hive 'LocalMachine' -SubKey $subKey -Name $name -Kind DWord -Value ([int]$original.Value)
        }
        else {
            Remove-RegistryValueRaw -Hive 'LocalMachine' -SubKey $subKey -Name $name
        }
    }
    $after = Get-LatestRestoreSequence
    if ($after -le $before) {
        throw 'Checkpoint-Computer finished without an error but no new restore point was recorded.'
    }
    return $after
}

# ----------------------------------------------------------------------------
# Tweak steps
# ----------------------------------------------------------------------------
function Invoke-StepGpuScheduling {
    [CmdletBinding()]
    param()
    if ($script:OsBuild -lt 19041) {
        Add-Result -Id 'hags' -Description 'Hardware-accelerated GPU scheduling' -Status Skipped -Detail ('needs Windows 10 version 2004 (build 19041) or later; this is build {0}' -f $script:OsBuild)
        return
    }
    Set-TweakRegistry -Id 'hags' -Description 'Hardware-accelerated GPU scheduling (HwSchMode = 2)' -Hive LocalMachine `
        -SubKey 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Kind DWord -Value 2
    Write-Log -Level INFO -Message 'GPU scheduling only takes effect when the GPU and driver support it (WDDM 2.7 or later).'
    $script:NeedsRestart = $true
}

function Invoke-StepMmcss {
    [CmdletBinding()]
    param()
    $profileKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-TweakRegistry -Id 'network-throttling' -Description 'Disable multimedia network throttling (NetworkThrottlingIndex)' -Hive LocalMachine `
        -SubKey $profileKey -Name 'NetworkThrottlingIndex' -Kind DWord -Value 4294967295
    Set-TweakRegistry -Id 'system-responsiveness' -Description 'Reserve 10 percent CPU for background tasks (SystemResponsiveness)' -Hive LocalMachine `
        -SubKey $profileKey -Name 'SystemResponsiveness' -Kind DWord -Value 10
    # Microsoft documents GPU Priority as unused and treats Priority as 2 whenever the category is High, so only the category is set.
    Set-TweakRegistry -Id 'games-scheduling' -Description 'Games task scheduling category High (MMCSS)' -Hive LocalMachine `
        -SubKey ($profileKey + '\Tasks\Games') -Name 'Scheduling Category' -Kind String -Value 'High' -RequireKey
}

function Invoke-StepNicPower {
    [CmdletBinding()]
    param()
    $description = 'Network adapter power saving off'
    if ($script:IsPortable) {
        Add-Result -Id 'nic-power' -Description $description -Status Skipped -Detail 'portable computer detected; adapter power saving is kept to protect battery life'
        return
    }
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { [string]$_.Status -eq 'Up' })
    if ($adapters.Count -eq 0) {
        Add-Result -Id 'nic-power' -Description $description -Status Skipped -Detail 'no connected physical network adapters'
        return
    }
    foreach ($adapter in $adapters) {
        $name = [string]$adapter.Name
        $id = 'nic-power:' + $name
        $label = '{0} ({1})' -f $description, $name
        try {
            $power = Get-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $power) {
                Add-Result -Id $id -Description $label -Status Skipped -Detail 'adapter does not expose power management'
                continue
            }
            $state = [string]$power.AllowComputerToTurnOffDevice
            if ($state -ne 'Enabled') {
                Add-Result -Id $id -Description $label -Status Skipped -Detail ('setting is {0}' -f $state)
                continue
            }
            if ($script:Opt['DryRun']) {
                Add-Result -Id $id -Description $label -Status DryRun -Detail 'would disable AllowComputerToTurnOffDevice'
                continue
            }
            Add-Baseline -Entry @{ Key = ('Nic|{0}' -f $name); Type = 'Nic'; Name = $name; Value = $state }
            Write-Log -Level INFO -Message ('Changing this setting restarts adapter {0}; the connection drops for a few seconds.' -f $name)
            $power.AllowComputerToTurnOffDevice = 'Disabled'
            $power | Set-NetAdapterPowerManagement -ErrorAction Stop
            $after = [string](Get-NetAdapterPowerManagement -Name $name -ErrorAction Stop).AllowComputerToTurnOffDevice
            if ($after -ne 'Disabled') { throw ('the driver still reports {0}' -f $after) }
            Add-Result -Id $id -Description $label -Status Applied
        }
        catch {
            Add-Result -Id $id -Description $label -Status Failed -Detail $_.Exception.Message
        }
    }
}

function Invoke-StepPagingExecutive {
    [CmdletBinding()]
    param()
    $description = 'Keep kernel code in RAM (DisablePagingExecutive)'
    if ($script:RamGb -lt 16) {
        Add-Result -Id 'paging-executive' -Description $description -Status Skipped -Detail ('needs 16 GB RAM or more; found {0} GB' -f $script:RamGb)
        return
    }
    Set-TweakRegistry -Id 'paging-executive' -Description $description -Hive LocalMachine `
        -SubKey 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'DisablePagingExecutive' -Kind DWord -Value 1
    $script:NeedsRestart = $true
}

function Invoke-StepMenuDelay {
    [CmdletBinding()]
    param()
    $sid = Get-TargetUserSid
    Write-Log -Level INFO -Message ('Per-user setting is applied to the profile of {0}.' -f $sid)
    Set-TweakRegistry -Id 'menu-show-delay' -Description 'Menu show delay 0 ms (MenuShowDelay)' -Hive Users `
        -SubKey ('{0}\Control Panel\Desktop' -f $sid) -Name 'MenuShowDelay' -Kind String -Value '0'
    $script:NeedsSignOut = $true
}

function Invoke-StepUsbSuspend {
    [CmdletBinding()]
    param()
    $modes = @('AC')
    if ($script:IsPortable) {
        Write-Log -Level INFO -Message 'Portable computer: USB selective suspend stays enabled on battery.'
    }
    else {
        $modes += 'DC'
    }
    Set-TweakPower -Id 'usb-selective-suspend' -Description 'USB selective suspend off' -SubGroup $script:GuidSubUsb `
        -Setting $script:GuidUsbSelectiveSuspend -Modes $modes -Value 0
}

function Invoke-StepMouse {
    [CmdletBinding()]
    param()
    $sid = Get-TargetUserSid
    $key = '{0}\Control Panel\Mouse' -f $sid
    Set-TweakRegistry -Id 'mouse-speed' -Description 'Pointer acceleration off (MouseSpeed)' -Hive Users -SubKey $key -Name 'MouseSpeed' -Kind String -Value '0'
    Set-TweakRegistry -Id 'mouse-threshold1' -Description 'Pointer acceleration off (MouseThreshold1)' -Hive Users -SubKey $key -Name 'MouseThreshold1' -Kind String -Value '0'
    Set-TweakRegistry -Id 'mouse-threshold2' -Description 'Pointer acceleration off (MouseThreshold2)' -Hive Users -SubKey $key -Name 'MouseThreshold2' -Kind String -Value '0'
    $script:NeedsSignOut = $true
}

function Invoke-StepCpuMinState {
    [CmdletBinding()]
    param()
    Set-TweakPower -Id 'cpu-min-state' -Description 'Minimum processor state 100 percent' -SubGroup $script:GuidSubProcessor `
        -Setting $script:GuidProcThrottleMin -Modes @('AC') -Value 100
}

function Invoke-StepSysMain {
    [CmdletBinding()]
    param()
    $id = 'sysmain'
    $description = 'Disable SysMain (Superfetch)'
    $media = Get-SystemDriveMediaType
    if ($media -ne 'SSD') {
        Add-Result -Id $id -Description $description -Status Skipped -Detail ('system drive media type is {0}, not a confirmed SSD' -f $media)
        return
    }
    if ($script:RamGb -lt 8) {
        Add-Result -Id $id -Description $description -Status Skipped -Detail ('needs 8 GB RAM or more; found {0} GB' -f $script:RamGb)
        return
    }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='SysMain'" -ErrorAction Stop
    if ($null -eq $service) {
        Add-Result -Id $id -Description $description -Status Skipped -Detail 'service not present'
        return
    }
    if ($service.StartMode -eq 'Disabled') {
        Add-Result -Id $id -Description $description -Status Skipped -Detail 'already disabled'
        return
    }
    if ($script:Opt['DryRun']) {
        Add-Result -Id $id -Description $description -Status DryRun -Detail ('would disable the service (start mode is {0})' -f $service.StartMode)
        return
    }
    $delayed = $false
    if (@($service.PSObject.Properties.Name) -contains 'DelayedAutoStart') { $delayed = [bool]$service.DelayedAutoStart }
    Add-Baseline -Entry @{
        Key = 'Service|SysMain'; Type = 'Service'; Name = 'SysMain'; StartMode = [string]$service.StartMode
        Delayed = $delayed; WasRunning = ([string]$service.State -eq 'Running')
    }
    Set-ServiceStartMode -Name 'SysMain' -Mode 'disabled'
    if ([string]$service.State -eq 'Running') {
        try {
            Stop-Service -Name 'SysMain' -Force -ErrorAction Stop
        }
        catch {
            Write-Log -Level WARN -Message ('SysMain is disabled but could not be stopped now; it stops at the next restart: {0}' -f $_.Exception.Message)
        }
    }
    $after = Get-CimInstance -ClassName Win32_Service -Filter "Name='SysMain'" -ErrorAction Stop
    if ($after.StartMode -ne 'Disabled') { throw ('start mode is still {0} after the change' -f $after.StartMode) }
    Add-Result -Id $id -Description $description -Status Applied
}

function Invoke-StepTdr {
    [CmdletBinding()]
    param()
    $key = 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    Write-Log -Level WARN -Message 'Microsoft documents the TDR keys as driver-development settings and advises end users not to change them.'
    Set-TweakRegistry -Id 'tdr-delay' -Description 'GPU timeout 10 s (TdrDelay, default 2)' -Hive LocalMachine -SubKey $key -Name 'TdrDelay' -Kind DWord -Value 10
    Set-TweakRegistry -Id 'tdr-ddi-delay' -Description 'GPU driver wait 10 s (TdrDdiDelay, default 5)' -Hive LocalMachine -SubKey $key -Name 'TdrDdiDelay' -Kind DWord -Value 10
    $script:NeedsRestart = $true
}

# ----------------------------------------------------------------------------
# Undo
# ----------------------------------------------------------------------------
function Restore-RegistryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    if (-not [bool]$Entry.Existed) {
        Remove-RegistryValueRaw -Hive ([string]$Entry.Hive) -SubKey ([string]$Entry.SubKey) -Name ([string]$Entry.Name)
        return
    }
    $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$Entry.Kind)
    $value = if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { [int]$Entry.Value } else { [string]$Entry.Value }
    Set-RegistryValueRaw -Hive ([string]$Entry.Hive) -SubKey ([string]$Entry.SubKey) -Name ([string]$Entry.Name) -Kind $kind -Value $value
}

function Restore-PowerEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    Set-PowerValue -Scheme ([string]$Entry.Scheme) -SubGroup ([string]$Entry.SubGroup) -Setting ([string]$Entry.Setting) `
        -Mode ([string]$Entry.Mode) -Value ([int]$Entry.Value)
    $script:PowerSchemesToApply[[string]$Entry.Scheme] = $true
}

function Restore-ServiceEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    $mode = switch ([string]$Entry.StartMode) {
        'Auto' { if ([bool]$Entry.Delayed) { 'delayed-auto' } else { 'auto' } }
        'Manual' { 'demand' }
        'Disabled' { 'disabled' }
        default { throw ('Unsupported recorded start mode {0}.' -f $Entry.StartMode) }
    }
    Set-ServiceStartMode -Name ([string]$Entry.Name) -Mode $mode
    if ([bool]$Entry.WasRunning -and $mode -ne 'disabled') {
        try {
            Start-Service -Name ([string]$Entry.Name) -ErrorAction Stop
        }
        catch {
            Write-Log -Level WARN -Message ('{0} was restored but could not be started now: {1}' -f $Entry.Name, $_.Exception.Message)
        }
    }
}

function Restore-NicEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    $power = Get-NetAdapterPowerManagement -Name ([string]$Entry.Name) -ErrorAction Stop
    $power.AllowComputerToTurnOffDevice = [string]$Entry.Value
    $power | Set-NetAdapterPowerManagement -ErrorAction Stop
}

function Invoke-Undo {
    [CmdletBinding()]
    param()
    $entries = @($script:Baseline)
    if ($entries.Count -eq 0) {
        Write-Log -Level WARN -Message ('Nothing to undo: no recorded values were found in {0}.' -f $script:BaselineFile)
        return
    }
    Write-Log -Level INFO -Message ('Restoring {0} recorded value(s).' -f $entries.Count)
    foreach ($entry in $entries) {
        $id = [string]$entry.Key
        try {
            if ($script:Opt['DryRun']) {
                Add-Result -Id $id -Description ('Restore {0}' -f $entry.Type) -Status DryRun -Detail 'would restore the recorded value'
                continue
            }
            switch ([string]$entry.Type) {
                'Registry' { Restore-RegistryEntry -Entry $entry }
                'Power' { Restore-PowerEntry -Entry $entry }
                'Service' { Restore-ServiceEntry -Entry $entry }
                'Nic' { Restore-NicEntry -Entry $entry }
                default { throw ('Unknown baseline entry type {0}.' -f $entry.Type) }
            }
            Add-Result -Id $id -Description ('Restore {0}' -f $entry.Type) -Status Restored
        }
        catch {
            Add-Result -Id $id -Description ('Restore {0}' -f $entry.Type) -Status Failed -Detail $_.Exception.Message
        }
    }
    if (-not $script:Opt['DryRun']) {
        Invoke-PowerApply
        $failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })
        if ($failed.Count -eq 0) {
            $archive = Join-Path -Path $script:AppDir -ChildPath ('baseline_restored_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Move-Item -LiteralPath $script:BaselineFile -Destination $archive -Force
            Write-Log -Level INFO -Message ('Baseline archived as {0}.' -f $archive)
        }
        else {
            Write-Log -Level WARN -Message 'Some values could not be restored; the baseline file was kept so /undo can be run again.'
        }
    }
    $script:NeedsRestart = $true
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
function Enter-SingleInstance {
    [CmdletBinding()]
    param()
    $script:Mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, 'Global\WindowsPerformanceTweaks')
    try {
        $script:MutexHeld = $script:Mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $script:MutexHeld = $true
    }
    return $script:MutexHeld
}

function Wait-ForKey {
    [CmdletBinding()]
    param()
    if ($script:SkipPause) { return }
    if ($null -ne $script:Opt -and $script:Opt['NoPause']) { return }
    try {
        if ([Console]::IsInputRedirected) { return }
        Write-Host 'Press any key to close this window...'
        [void][Console]::ReadKey($true)
    }
    catch {
        Write-Log -Level INFO -Message ('Not waiting for a key press: {0}' -f $_.Exception.Message)
    }
}

function Show-Summary {
    [CmdletBinding()]
    param()
    $applied = @($script:Results | Where-Object { $_.Status -eq 'Applied' -or $_.Status -eq 'Restored' }).Count
    $skipped = @($script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $dry = @($script:Results | Where-Object { $_.Status -eq 'DryRun' }).Count
    Write-Log -Level INFO -Message ('Summary: {0} applied, {1} skipped, {2} failed, {3} dry-run.' -f $applied, $skipped, $failed, $dry)
    foreach ($item in @($script:Results | Where-Object { $_.Status -eq 'Failed' })) {
        Write-Log -Level ERROR -Message ('Failed: {0} - {1}' -f $item.Description, $item.Detail)
    }
    if ($failed -gt 0) {
        Write-Log -Level WARN -Message 'Finished with errors. Review the messages above or the log file.'
    }
    elseif ($dry -gt 0) {
        Write-Log -Level INFO -Message 'Dry run complete. Nothing was changed.'
    }
    else {
        Write-Log -Level OK -Message 'Finished without errors.'
    }
    if ($script:NeedsRestart -and $dry -eq 0) {
        Write-Log -Level INFO -Message 'Restart Windows for all changes to take effect.'
    }
    if ($script:NeedsSignOut -and -not $script:NeedsRestart -and $dry -eq 0) {
        Write-Log -Level INFO -Message 'Sign out and back in for the per-user changes to take effect.'
    }
    if ($null -ne $script:LogFile) {
        Write-Log -Level INFO -Message ('Log file: {0}' -f $script:LogFile)
    }
    Write-Log -Level INFO -Message 'To revert the changes made by this script, run it again with /undo.'
}

function Invoke-Main {
    [CmdletBinding()]
    param()
    $script:Opt = ConvertFrom-ArgumentString -Text $env:OPTWIN_ARGS
    $opt = $script:Opt

    if ($opt['Help'] -or $opt['Unknown'].Count -gt 0) {
        if ($opt['Unknown'].Count -gt 0) {
            Write-Host ('Unknown option(s): {0}' -f ($opt['Unknown'] -join ' ')) -ForegroundColor Red
        }
        Show-Usage
        $script:ExitCode = if ($opt['Unknown'].Count -gt 0) { 2 } else { 0 }
        return
    }

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Log -Level ERROR -Message ('PowerShell is running in {0} mode (for example under an application control policy); this script needs FullLanguage.' -f $ExecutionContext.SessionState.LanguageMode)
        $script:ExitCode = 3
        return
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Log -Level ERROR -Message 'Windows PowerShell 5.1 or later is required.'
        $script:ExitCode = 3
        return
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $script:OsBuild = [int]$os.BuildNumber
    if ([int]$os.ProductType -ne 1 -or $script:OsBuild -lt 10240) {
        Write-Log -Level ERROR -Message ('Only Windows 10 and Windows 11 client editions are supported (found {0}, build {1}).' -f $os.Caption, $script:OsBuild)
        $script:ExitCode = 3
        return
    }

    if (-not (Test-Elevated)) {
        if ($opt['NoElevate']) {
            Write-Log -Level ERROR -Message 'Administrator rights are required. Run this script as administrator.'
            $script:ExitCode = 4
            return
        }
        Write-Log -Level INFO -Message 'Administrator rights are required. Requesting elevation (UAC prompt)...'
        try {
            $startArgs = @{ FilePath = $env:OPTWIN_SELF; Verb = 'RunAs' }
            if (-not [string]::IsNullOrWhiteSpace($env:OPTWIN_ARGS)) { $startArgs['ArgumentList'] = $env:OPTWIN_ARGS }
            Start-Process @startArgs
            $script:SkipPause = $true
            $script:ExitCode = 0
        }
        catch {
            Write-Log -Level ERROR -Message ('Elevation failed or was cancelled: {0}' -f $_.Exception.Message)
            $script:ExitCode = 4
        }
        return
    }

    if (-not (Enter-SingleInstance)) {
        Write-Log -Level ERROR -Message 'Another instance of this script is already running.'
        $script:ExitCode = 3
        return
    }

    try {
        New-Item -ItemType Directory -Path (Join-Path -Path $script:AppDir -ChildPath 'logs') -Force | Out-Null
    }
    catch {
        Write-Log -Level ERROR -Message ('Cannot create {0}: {1}' -f $script:AppDir, $_.Exception.Message)
        $script:ExitCode = 3
        return
    }
    $script:LogFile = Join-Path -Path (Join-Path -Path $script:AppDir -ChildPath 'logs') -ChildPath ('optimize_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $bytesPerGiB = 1073741824
    $script:RamGb = [math]::Round(([double]$computer.TotalPhysicalMemory) / $bytesPerGiB, 1)
    $script:IsPortable = Test-PortableComputer

    Write-Log -Level INFO -Message ('Windows performance tweaks {0}' -f $script:Version)
    Write-Log -Level INFO -Message ('{0}, build {1}, PowerShell {2}, 64-bit process: {3}' -f $os.Caption, $script:OsBuild, $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)
    Write-Log -Level INFO -Message ('User {0}, RAM {1} GB, portable computer: {2}' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, $script:RamGb, $script:IsPortable)
    Write-Log -Level INFO -Message ('Options: {0}' -f (($opt.Keys | Where-Object { $opt[$_] -is [bool] -and $opt[$_] } | Sort-Object) -join ', '))

    Import-Baseline

    if ($opt['Undo']) {
        Invoke-Undo
        Show-Summary
        $script:ExitCode = if (@($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { 1 } else { 0 }
        return
    }

    if ($opt['DryRun']) {
        Write-Log -Level DRY -Message 'Dry run: nothing will be changed.'
    }
    elseif ($opt['NoRestorePoint']) {
        Write-Log -Level WARN -Message 'Skipping the restore point (/norestorepoint). The built-in /undo still works.'
    }
    else {
        Write-Log -Level INFO -Message 'Creating a system restore point...'
        try {
            $sequence = New-TweakRestorePoint
            Write-Log -Level OK -Message ('Restore point created (sequence number {0}).' -f $sequence)
        }
        catch {
            Write-Log -Level ERROR -Message ('Could not create a restore point: {0}' -f $_.Exception.Message)
            Write-Log -Level ERROR -Message 'No changes were made. Turn on System Protection for the system drive, or run again with /norestorepoint.'
            $script:ExitCode = 5
            return
        }
    }

    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $steps.Add(@{ Name = 'Hardware-accelerated GPU scheduling'; Run = { Invoke-StepGpuScheduling } })
    $steps.Add(@{ Name = 'Multimedia scheduler (network throttling, responsiveness, games task)'; Run = { Invoke-StepMmcss } })
    $steps.Add(@{ Name = 'Network adapter power saving'; Run = { Invoke-StepNicPower } })
    $steps.Add(@{ Name = 'Keep kernel code in RAM'; Run = { Invoke-StepPagingExecutive } })
    $steps.Add(@{ Name = 'Menu show delay'; Run = { Invoke-StepMenuDelay } })
    $steps.Add(@{ Name = 'USB selective suspend'; Run = { Invoke-StepUsbSuspend } })
    if ($opt['Mouse']) { $steps.Add(@{ Name = 'Pointer acceleration'; Run = { Invoke-StepMouse } }) }
    if ($opt['Cpu']) { $steps.Add(@{ Name = 'Minimum processor state'; Run = { Invoke-StepCpuMinState } }) }
    if ($opt['SysMain']) { $steps.Add(@{ Name = 'SysMain (Superfetch)'; Run = { Invoke-StepSysMain } }) }
    if ($opt['Tdr']) { $steps.Add(@{ Name = 'GPU timeout (TDR)'; Run = { Invoke-StepTdr } }) }

    $notSelected = @()
    if (-not $opt['Mouse']) { $notSelected += '/mouse' }
    if (-not $opt['Cpu']) { $notSelected += '/cpu' }
    if (-not $opt['SysMain']) { $notSelected += '/sysmain' }
    if (-not $opt['Tdr']) { $notSelected += '/tdr' }
    if ($notSelected.Count -gt 0) {
        Write-Log -Level INFO -Message ('Optional tweaks not selected: {0} (or /all).' -f ($notSelected -join ' '))
    }

    $index = 0
    foreach ($step in $steps) {
        $index++
        Write-Log -Level INFO -Message ('[{0}/{1}] {2}' -f $index, $steps.Count, $step['Name'])
        try {
            & $step['Run']
        }
        catch {
            Add-Result -Id ([string]$step['Name']) -Description ([string]$step['Name']) -Status Failed -Detail $_.Exception.Message
        }
    }

    try {
        Invoke-PowerApply
    }
    catch {
        Add-Result -Id 'power-apply' -Description 'Re-activate the power scheme' -Status Failed -Detail $_.Exception.Message
    }

    Show-Summary
    $script:ExitCode = if (@($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { 1 } else { 0 }
}

# OPTWIN_NORUN lets the test suite load the functions above without running them.
if ([string]::IsNullOrEmpty($env:OPTWIN_NORUN)) {
    try {
        Invoke-Main
    }
    catch {
        $script:ExitCode = 1
        Write-Log -Level ERROR -Message ('Unexpected error: {0}' -f $_.Exception.Message)
        Write-Log -Level ERROR -Message ('At: {0}' -f $_.ScriptStackTrace)
    }
    finally {
        if ($script:MutexHeld -and $null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() }
    }
    Wait-ForKey
    exit $script:ExitCode
}
