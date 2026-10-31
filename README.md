# WindowsRescue 🚀

![Windows Repair](https://img.shields.io/badge/Platform-Windows-blue?style=flat-square&logo=windows)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)
![Version](https://img.shields.io/badge/Version-2.0.0-brightgreen?style=flat-square)

Welcome to **WindowsRescue** – your ultimate toolkit for fixing, optimizing, maintaining, and setting up your Windows 10/11 system like a pro! 🛠️ Whether you're dealing with boot issues, disk errors, need to update everything, set up development environments, or organize your files, these scripts have got you covered.

No more digging through forums or running manual commands – just fire up these battle-tested CMD and PowerShell scripts and let them do the heavy lifting!

## Why This Repo? 💡
Windows can be a beast sometimes – corrupted files, slow performance, network glitches, outdated software, and development environment headaches... you name it. This repo consolidates powerful, automated solutions into one place, from system repairs to development setup to file organization. All scripts are designed to be:
- **Safe & Non-Destructive**: They prompt for admin rights and back up where needed.
- **Easy to Use**: Just double-click or run from Command Prompt/PowerShell.
- **Comprehensive**: Cover everything from system repairs to dev environment setup.

Inspired by real-world troubleshooting and development workflows, these scripts use built-in Windows tools like DISM, SFC, CHKDSK, winget, and more, wrapped in user-friendly batches.

## Features ✨
Here's a breakdown of the goodies:

### Core Repair Tools
- **repair_boot.cmd**: Fix boot issues and restore your system's startup sequence.
- **repair_certificates.cmd**: Comprehensive certificate store repair, verification, and cache cleanup using certutil.
- **repair_windows.cmd**: Run DISM and SFC scans to repair corrupted system files.
- **repair_drive_quick.cmd / mid.cmd / max.cmd**: Quick, medium, or thorough disk checks and repairs.
- **repair_wmi.cmd**: Rebuild and repair Windows Management Instrumentation (WMI) repository.

### System Updates & Maintenance
- **update_windows.ps1**: Comprehensive Windows system updates including OS, drivers, and optional features.
- **update_windows_programs.cmd**: Update all installed programs using Windows Package Manager (winget).
- **update_windows_store.ps1**: Update Windows Store apps and reset store cache if needed.

### Disk Optimization
- **optimize_drives.cmd**: Defragment/TRIM and optimize your drives for peak performance.
- **free_space_quick.cmd / mid.cmd / max.cmd**: Free up disk space by cleaning temp files, logs, and more.

### Network & Connectivity Fixes
- **flush_dns.cmd**: Clear DNS cache to resolve browsing issues.
- **reset_tcpip.cmd**: Reset TCP/IP stack.
- **reset_winsock.cmd**: Reset Winsock catalog.
- **reset_windows_update.cmd**: Fix stuck Windows Update services.
- **repair_time_service.cmd**: Fix Windows Time Service synchronization issues and repair corrupted time service configuration.

### Performance Boosters
- **enable_ultimate_performance.cmd**: Unlock the Ultimate Performance power plan for high-end hardware.
- **optimize_ntfs.cmd**: Tune NTFS file system settings.

### Utility & Organization Tools (in `./Misc/`)
- **get_system_info.cmd**: Generate a detailed system report.
- **print_queue_viewer.ps1**: View and manage print queues.
- **repair_volumes.cmd**: Alternative repair all volumes on your system method.
- **tts.cmd**: Text-to-Speech utility for fun or accessibility.

### Cross-Platform Tools (in `./Misc/`)
- **repair_ubuntu.sh**: Comprehensive Ubuntu/Linux system repair and integrity check script.

## Getting Started 🚀
1. **Clone the Repo**:
   ```
   git clone https://github.com/tboy1337/WindowsRescue.git
   cd WindowsRescue
   ```

2. **Requirements**:
   - Windows 10/11 (with admin privileges).
   - PowerShell 5.1+ (included in Windows).
   - Windows Package Manager (winget) for program updates.
   - Optional: Python 3.x for development setup scripts.
   - Optional: Node.js for development setup scripts.
   - Optional: WSL/Ubuntu for cross-platform repair tools.

3. **Run a Script**:
   - Right-click a `.cmd` file and select "Run as administrator".
   - For `.ps1` files, right click and select "Run with PowerShell".
   - **Pro Tip**: Always back up important data before running repairs!

## Usage Examples 📝
- **Fix system files**: `repair_windows.cmd`
- **Repair certificates**: `repair_certificates.cmd`
- **Optimize disk**: `optimize_drives.cmd`
- **Update all programs**: `update_windows_programs.cmd`
- **Full Windows update**: `update_windows.ps1`
- **Repair time service**: `repair_time_service.cmd`
- **Repair Ubuntu system** (in WSL): `Misc/repair_ubuntu.sh`

For detailed usage, check each script's comments.

## Contributing 🤝
Love fixing Windows? Fork this repo, add your own scripts, and submit a PR!

## License 📄
This project is licensed under the CRL License - see [LICENSE.md](./LICENSE.md) for details.

---

*Disclaimer: These scripts are provided as-is. Always run with caution and understand what they do. Not responsible for any system issues.*
