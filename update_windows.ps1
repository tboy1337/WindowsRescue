<# Self-Elevating PowerShell Script
This script automatically handles execution policy and administrator elevation
#>

# Check if we're running with the right parameters (bypass execution policy and elevated)
$IsElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
$CurrentPolicy = Get-ExecutionPolicy -Scope Process

# If we're not elevated or don't have bypass policy, restart with proper parameters
if (-NOT $IsElevated -or $CurrentPolicy -eq "Undefined" -or $CurrentPolicy -eq "Restricted") {
    Write-Host "Initializing script with proper permissions..." -ForegroundColor Yellow
    try {
        $ScriptPath = $MyInvocation.MyCommand.Path
        $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        if (-NOT $IsElevated) {
            # Need elevation
            $ChildProcess = Start-Process PowerShell -Verb RunAs -ArgumentList $Arguments -PassThru -Wait
        } else {
            # Just need execution policy bypass
            $ChildProcess = Start-Process PowerShell -ArgumentList $Arguments -PassThru -Wait
        }
        exit $ChildProcess.ExitCode
    }
    catch {
        Write-Error "Failed to restart script with proper parameters: $_"
        Write-Host "Please run this script as Administrator with execution policy bypass." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        exit 1
    }
}

<#
.SYNOPSIS
    Windows Update Script with User Notification
.DESCRIPTION
    Downloads and installs Windows updates using PowerShell, with user notification
    and 60-second countdown before restart if required.
.NOTES
    Automatically handles elevation and execution policy
#>

# Function to show countdown with option to cancel
function Show-RestartCountdown {
    param(
        [int]$Seconds = 60
    )

    Write-Host -Object "`n" -ForegroundColor Yellow
    Write-Host -Object ("=" * 70) -ForegroundColor Yellow
    Write-Host "  RESTART REQUIRED - SAVE YOUR WORK NOW!" -ForegroundColor Red
    Write-Host -Object ("=" * 70) -ForegroundColor Yellow
    Write-Host "`nUpdates have been installed and require a restart to complete." -ForegroundColor White
    Write-Host "The system will restart automatically in $Seconds seconds." -ForegroundColor White
    Write-Host "`nPress 'C' to cancel the restart, or any other key to restart immediately." -ForegroundColor Cyan
    Write-Host "Or simply wait for the countdown to complete." -ForegroundColor Cyan
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`rRestart in: $i seconds... " -NoNewline -ForegroundColor Red

        # Check if user pressed a key
        if ([Environment]::UserInteractive) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'C') {
                        Write-Host "`n`nRestart cancelled by user." -ForegroundColor Green
                        Write-Host "Please restart your computer manually when convenient to complete the updates." -ForegroundColor Yellow
                        return $false
                    } else {
                        Write-Host "`n`nRestarting immediately..." -ForegroundColor Yellow
                        return $true
                    }
                }
            }
            catch {
                # Non-interactive host; continue countdown
            }
        }

        Start-Sleep -Seconds 1
    }

    Write-Host "`n`nTime's up! Restarting now..." -ForegroundColor Yellow
    return $true
}

# Function to install or update the PSWindowsUpdate module
function Install-WindowsUpdateModule {
    Write-Host "Checking for PSWindowsUpdate module..." -ForegroundColor Cyan

    $InstalledModules = @(Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending)
    if ($InstalledModules.Count -eq 0) {
        Write-Host "PSWindowsUpdate module not found. Installing..." -ForegroundColor Yellow
        try {
            Write-Host "Installing NuGet provider..." -ForegroundColor Cyan
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -Confirm:$false | Out-Null
            Write-Host "Setting PSGallery as trusted repository..." -ForegroundColor Cyan
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        catch {
            Write-Error "Failed to prepare PSWindowsUpdate module installation: $_"
            exit 1
        }
    }

    try {
        $LatestModule = Find-Module -Name PSWindowsUpdate -Repository PSGallery -ErrorAction Stop
    }
    catch {
        if ($InstalledModules.Count -eq 0) {
            Write-Error "Failed to find PSWindowsUpdate on PSGallery: $_"
            exit 1
        }
        Write-Warning "Could not check PSGallery for a newer PSWindowsUpdate version. Using installed version $($InstalledModules[0].Version): $_"
        $LatestModule = $InstalledModules[0]
    }

    if ($InstalledModules.Count -eq 0 -or $InstalledModules[0].Version -lt $LatestModule.Version) {
        Write-Host "Installing PSWindowsUpdate version $($LatestModule.Version)..." -ForegroundColor Yellow
        try {
            Install-Module -Name PSWindowsUpdate -Force -AllowClobber -Scope AllUsers -Confirm:$false -SkipPublisherCheck -ErrorAction Stop
            Write-Host "PSWindowsUpdate module installed or upgraded successfully." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install or upgrade PSWindowsUpdate module: $_"
            exit 1
        }
    } else {
        Write-Host "PSWindowsUpdate module is up to date (version $($InstalledModules[0].Version))." -ForegroundColor Green
    }

    # Import the module
    try {
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to import PSWindowsUpdate module: $_"
        exit 1
    }
}

# Main script
Write-Host "Windows Update Script Starting..." -ForegroundColor Green
Write-Host "Time: $(Get-Date)" -ForegroundColor Gray

# At this point, we're running as administrator with bypass execution policy

# Install/Import the Windows Update module
Install-WindowsUpdateModule

Write-Host "`nChecking for available updates..." -ForegroundColor Cyan

try {
    # Get list of available updates
    $Updates = @(Get-WUList -MicrosoftUpdate -Verbose)

    if ($Updates.Count -eq 0) {
        Write-Host "No updates available. Your system is up to date!" -ForegroundColor Green
        Write-Host "`nExiting in 10 seconds..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
        exit 0
    }

    Write-Host "`nFound $($Updates.Count) update(s):" -ForegroundColor Yellow
    foreach ($Update in $Updates) {
        Write-Host "  - $($Update.Title)" -ForegroundColor White
    }

    Write-Host "`nStarting update download and installation..." -ForegroundColor Cyan
    Write-Host "This may take several minutes depending on update size." -ForegroundColor Gray

    # Install updates and capture the result
    $InstallResult = @(Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose)

    Write-Host "`nUpdate installation completed!" -ForegroundColor Green

    # Check if restart is required
    $RestartRequired = $false
    foreach ($Result in $InstallResult) {
        if ($Result.RebootRequired) {
            $RestartRequired = $true
            break
        }
    }

    # Also check using Get-WURebootStatus if available
    try {
        $RebootStatus = Get-WURebootStatus
        if ($RebootStatus.RebootRequired) {
            $RestartRequired = $true
        }
    }
    catch {
        # Fallback: check Windows Update registry keys for pending restart
        $RebootKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
        )
        foreach ($RebootKey in $RebootKeys) {
            if (Test-Path $RebootKey) {
                $RestartRequired = $true
                break
            }
        }
    }

    if ($RestartRequired) {
        $ShouldRestart = Show-RestartCountdown -Seconds 60

        if ($ShouldRestart) {
            Write-Host "Initiating system restart..." -ForegroundColor Red
            Start-Sleep -Seconds 2
            Restart-Computer -Force
        }
    } else {
        Write-Host "`nNo restart required. All updates have been installed successfully!" -ForegroundColor Green
        Write-Host "`nExiting in 10 seconds..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
    }

} catch {
    Write-Error "An error occurred during the update process: $_"
    Write-Host "`nYou may want to run Windows Update manually or try again later." -ForegroundColor Yellow
    Write-Host "`nExiting in 10 seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
    exit 1
}

Write-Host "`nScript completed successfully!" -ForegroundColor Green
