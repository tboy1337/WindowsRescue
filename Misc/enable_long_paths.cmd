@echo off
:: Enables Win32 long path support (paths longer than 260 characters).

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script must be run as Administrator.
    echo Right-click the file and choose "Run as administrator".
    timeout /t 10 /nobreak
    exit /b 1
)

reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
if %errorlevel% equ 0 (
    echo LongPathsEnabled has been set to 1.
    echo You may need to restart for all applications to pick up the change.
    timeout /t 10 /nobreak
    exit /b 0
) else (
    echo Failed to set LongPathsEnabled.
    timeout /t 10 /nobreak
    exit /b 1
)
