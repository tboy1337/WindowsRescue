#!/bin/bash

# Ubuntu Linux System Integrity Check and Repair Script

# Exit on error, but handle errors gracefully in functions
set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
HAS_CORRUPTION=0
REPAIR_NEEDED=0
REPAIR_SUCCEEDED=0
DRY_RUN=0
LOG_FILE=""
TEMP_FILES=()

# Write output to console and log file when logging is initialized
write_log() {
    if [[ -n "$LOG_FILE" ]]; then
        echo -e "$1" | tee -a "$LOG_FILE"
    else
        echo -e "$1"
    fi
}

# Function to print colored output with timestamps
print_status() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    write_log "${BLUE}${message}${NC}"
}

print_success() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"
    write_log "${GREEN}${message}${NC}"
}

print_warning() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1"
    write_log "${YELLOW}${message}${NC}"
}

print_error() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    write_log "${RED}${message}${NC}"
}

# Cleanup function to remove temporary files
cleanup() {
    local exit_code=$?
    
    # Remove all tracked temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
        fi
    done
    
    if [[ $exit_code -ne 0 ]]; then
        print_error "Script exited with error code: $exit_code"
    fi
    
    exit $exit_code
}

# Create secure temporary file and track it
create_temp_file() {
    local temp_file
    temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
}

# Usage function
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d, --dry-run    Show what would be done without making changes"
    echo "  -h, --help       Show this help message"
    echo "  -l, --log FILE   Specify log file location (default: auto-generated in /var/log)"
    echo ""
    echo "Examples:"
    echo "  $0                           # Run with default settings"
    echo "  $0 --dry-run                 # Preview mode only"
    echo "  $0 --log /custom/path.log    # Custom log file"
}

# Validate required commands are available
check_required_commands() {
    print_status "Validating required system commands..."
    local missing_commands=()
    local required_commands=("apt" "dpkg" "dmesg" "df" "awk" "grep" "wc" "timeout")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_error "Please install the missing commands and try again."
        exit 1
    fi
    
    print_success "All required commands are available"
}

# Parse command line arguments with proper validation
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -l|--log)
                if [[ -z "${2:-}" ]]; then
                    print_error "--log requires a filename argument"
                    show_usage
                    exit 1
                fi
                LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} This script requires root privileges."
        echo -e "${RED}[ERROR]${NC} Please run with: sudo $0"
        exit 1
    fi
}

# Initialize secure log file
init_log() {
    # Create secure log file if not specified
    if [[ -z "$LOG_FILE" ]]; then
        if [[ -d "/var/log" ]]; then
            LOG_FILE="/var/log/system_integrity_check_$(date +%Y%m%d_%H%M%S).log"
        else
            LOG_FILE=$(mktemp --suffix=.log /tmp/system_integrity_check.XXXXXX)
        fi
    fi
    
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        if ! mkdir -p "$log_dir"; then
            echo -e "${RED}[ERROR]${NC} Cannot create log directory: $log_dir"
            exit 1
        fi
    fi
    
    # Initialize log file with proper permissions
    {
        echo "=== System Integrity Check Started: $(date) ==="
        echo "=== Script: $0 ==="
        echo "=== User: $(whoami) ==="
        echo "=== PID: $$ ==="
        echo "=== Arguments: $* ==="
        echo "=================================================="
        echo ""
    } > "$LOG_FILE"
    
    # Secure log file permissions
    chmod 640 "$LOG_FILE"
    
    print_status "Log file: $LOG_FILE"
}

# Update package database with proper error handling
update_package_db() {
    print_status "Updating package database..."
    local temp_log
    temp_log=$(create_temp_file)
    
    if apt update > "$temp_log" 2>&1; then
        print_success "Package database updated successfully"
        return 0
    else
        local exit_code=$?
        print_error "Failed to update package database. Exit code: $exit_code"
        print_error "Error details:"
        tail -3 "$temp_log" | while IFS= read -r line; do
            print_error "  $line"
        done
        return 1
    fi
}

# Check for broken packages with improved error handling
check_broken_packages() {
    print_status "Checking for broken packages..."
    local temp_log
    temp_log=$(create_temp_file)
    
    # Check for packages with unmet dependencies
    if apt-get check > "$temp_log" 2>&1; then
        print_success "No broken packages detected"
    else
        print_warning "Found broken package dependencies"
        print_status "Error details:"
        head -5 "$temp_log" | while IFS= read -r line; do
            print_status "  $line"
        done
        HAS_CORRUPTION=1
        REPAIR_NEEDED=1
    fi
    
    # Check for packages in inconsistent state
    local broken_packages
    broken_packages=$(dpkg -l | grep -cE "^(iU|iF|iH)" || echo "0")
    if [[ $broken_packages -gt 0 ]]; then
        print_warning "Found $broken_packages packages in inconsistent state"
        HAS_CORRUPTION=1
        REPAIR_NEEDED=1
    fi
}

# Check package integrity with improved error handling
check_package_integrity() {
    print_status "Checking package integrity..."
    
    # Check if debsums is available
    if ! command -v debsums &> /dev/null; then
        if [[ $DRY_RUN -eq 1 ]]; then
            print_status "Would install debsums for integrity checking (dry-run mode)"
            return 0
        else
            print_status "Installing debsums for integrity checking..."
            local temp_log
            temp_log=$(create_temp_file)
            
            if apt install -y debsums > "$temp_log" 2>&1; then
                print_success "debsums installed successfully"
            else
                print_error "Failed to install debsums"
                tail -3 "$temp_log" | while IFS= read -r line; do
                    print_error "  $line"
                done
                return 1
            fi
        fi
    fi
    
    # Run debsums to check file integrity (only if not dry-run)
    if [[ $DRY_RUN -eq 0 ]]; then
        local temp_file
        temp_file=$(create_temp_file)
        
        print_status "Running package integrity check (this may take a few minutes)..."
        set +e
        timeout 300 debsums -c > "$temp_file" 2>&1
        local debsums_exit=$?
        set -e

        if [[ $debsums_exit -eq 0 ]]; then
            print_success "All package files have correct checksums"
        elif [[ $debsums_exit -eq 124 ]]; then
            print_warning "Package integrity check timed out after 300 seconds"
            HAS_CORRUPTION=1
        else
            local changed_files
            changed_files=$(grep -cE "changed|doesn't match" "$temp_file" 2>/dev/null || echo "0")
            if [[ "$changed_files" =~ ^[0-9]+$ ]] && [[ $changed_files -gt 0 ]]; then
                print_warning "Found $changed_files files with incorrect checksums"
                print_status "Run 'debsums -c' manually to see details"
                HAS_CORRUPTION=1
            else
                print_warning "Package integrity check reported issues (exit code: $debsums_exit)"
                HAS_CORRUPTION=1
            fi
        fi
    else
        print_status "Would check package file checksums (dry-run mode)"
    fi
}

# Check filesystem integrity with improved parsing
check_filesystem() {
    print_status "Checking filesystem integrity..."
    
    # Check for filesystem errors in dmesg and system logs
    if dmesg | grep -iE "filesystem error|ext[234]-fs error|corruption|journal error|journal abort|I/O error|superblock" > /dev/null 2>&1; then
        print_warning "Filesystem errors detected in kernel messages"
        HAS_CORRUPTION=1
    else
        print_success "No filesystem errors in kernel messages"
    fi
    
    # Check for filesystem errors in systemd journal
    if command -v journalctl &> /dev/null; then
        if journalctl --since="7 days ago" --grep="filesystem.*error|ext[234].*error" --no-pager -q > /dev/null 2>&1; then
            print_warning "Filesystem errors found in system journal (last 7 days)"
            HAS_CORRUPTION=1
        fi
    fi
    
    # Check disk usage with improved parsing
    local root_usage
    root_usage=$(df / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    
    if [[ -n "$root_usage" ]] && [[ "$root_usage" =~ ^[0-9]+$ ]]; then
        if [[ $root_usage -gt 95 ]]; then
            print_warning "Root filesystem is ${root_usage}% full - this may cause system issues"
        elif [[ $root_usage -gt 85 ]]; then
            print_status "Root filesystem is ${root_usage}% full"
        else
            print_status "Root filesystem usage: ${root_usage}%"
        fi
    else
        print_warning "Could not determine root filesystem usage"
    fi
    
    # Note about full filesystem check
    print_status "Note: Complete filesystem check requires unmounting and is not performed on running system"
    print_status "To perform full check, boot from live USB and run: fsck -f /dev/[root-device]"
}

# Repair broken packages with enhanced error handling
repair_packages() {
    if [[ $REPAIR_NEEDED -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            print_status "Would attempt to repair broken packages (dry-run mode)"
            print_status "Would run: apt --fix-broken install -y"
            print_status "Would run: dpkg --configure -a"
            return 0
        fi
        
        print_status "Attempting to repair broken packages..."
        local temp_log
        temp_log=$(create_temp_file)
        
        # Fix broken dependencies
        print_status "Fixing broken dependencies..."
        if apt --fix-broken install -y > "$temp_log" 2>&1; then
            print_success "Fixed broken package dependencies"
            REPAIR_SUCCEEDED=1
        else
            print_error "Failed to fix broken packages"
            tail -5 "$temp_log" | while IFS= read -r line; do
                print_error "  $line"
            done
        fi
        
        # Reconfigure packages that may be in a broken state
        print_status "Reconfiguring packages..."
        if dpkg --configure -a >> "$temp_log" 2>&1; then
            print_success "Package reconfiguration completed"
            REPAIR_SUCCEEDED=1
        else
            print_error "Failed to reconfigure packages"
            tail -5 "$temp_log" | while IFS= read -r line; do
                print_error "  $line"
            done
        fi
    fi
}

# Clean package cache and remove orphaned packages
cleanup_system() {
    if [[ $DRY_RUN -eq 1 ]]; then
        print_status "Would remove orphaned packages (dry-run mode)"
        print_status "Would clean package cache (dry-run mode)"
        return 0
    fi
    
    local temp_log
    temp_log=$(create_temp_file)
    
    print_status "Removing orphaned packages..."
    if apt autoremove -y > "$temp_log" 2>&1; then
        local removed
        removed=$(grep -c "Removing" "$temp_log" 2>/dev/null || echo "0")
        if [[ $removed -gt 0 ]]; then
            print_success "Removed $removed orphaned packages"
        else
            print_success "No orphaned packages to remove"
        fi
    else
        print_error "Failed to remove orphaned packages"
        tail -3 "$temp_log" | while IFS= read -r line; do
            print_error "  $line"
        done
    fi
    
    print_status "Cleaning package cache..."
    if apt autoclean >> "$temp_log" 2>&1; then
        print_success "Package cache cleaned"
    else
        print_error "Failed to clean package cache"
        tail -3 "$temp_log" | while IFS= read -r line; do
            print_error "  $line"
        done
    fi
}

# Check and repair GRUB if needed
check_grub() {
    print_status "Checking GRUB bootloader..."
    
    if command -v update-grub &> /dev/null; then
        if [[ $DRY_RUN -eq 1 ]]; then
            print_status "Would update GRUB configuration (dry-run mode)"
            return 0
        fi
        
        local temp_log
        temp_log=$(create_temp_file)
        
        # Update GRUB configuration
        if update-grub > "$temp_log" 2>&1; then
            print_success "GRUB configuration updated"
        else
            print_warning "Failed to update GRUB configuration"
            tail -3 "$temp_log" | while IFS= read -r line; do
                print_warning "  $line"
            done
        fi
    else
        print_status "GRUB not found, skipping bootloader check"
    fi
}

# Check system logs for critical errors
check_system_logs() {
    print_status "Checking system logs for critical errors..."
    
    # Check for recent critical errors in systemd journal
    local critical_errors=0
    if command -v journalctl &> /dev/null; then
        critical_errors=$(journalctl --since="24 hours ago" --priority=crit --no-pager -q 2>/dev/null | wc -l)
    fi
    
    if [[ $critical_errors -gt 0 ]]; then
        print_warning "Found $critical_errors critical errors in the last 24 hours"
        print_status "Run 'journalctl --since=\"24 hours ago\" --priority=crit' to view them"
    else
        print_success "No critical errors found in recent logs"
    fi
    
    # Check for kernel oops or panics
    if dmesg | grep -i "oops\|panic\|segfault\|general protection fault" > /dev/null 2>&1; then
        print_warning "Kernel errors detected in dmesg"
        print_status "Run 'dmesg | grep -i \"oops\\|panic\\|segfault\"' for details"
    else
        print_success "No kernel errors detected in dmesg"
    fi
}

# Check system services status
check_services() {
    print_status "Checking critical system services..."

    if ! command -v systemctl &> /dev/null; then
        print_status "systemctl not available, skipping service check"
        return 0
    fi

    local failed_services
    failed_services=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l) || true
    
    if [[ $failed_services -gt 0 ]]; then
        print_warning "Found $failed_services failed system services"
        print_status "Run 'systemctl --failed' to view them"
    else
        print_success "All system services are running normally"
    fi
}

# System summary with detailed reporting
print_summary() {
    echo
    echo "================================================"
    print_status "SYSTEM INTEGRITY SUMMARY"
    echo "================================================"
    
    if [[ $HAS_CORRUPTION -eq 1 ]]; then
        print_warning "Issues were detected during the scan"
    else
        print_success "No major issues detected"
    fi
    
    if [[ $REPAIR_NEEDED -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            print_status "Repairs would be attempted (dry-run mode)"
        else
            print_status "Repairs were attempted"
        fi
    fi
    
    echo "================================================"
    echo "System Information:"
    echo "  - OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")"
    echo "  - Kernel: $(uname -r)"
    echo "  - Uptime: $(uptime -p 2>/dev/null || uptime)"
    echo "  - Date: $(date)"
    echo "================================================"
}

# Main execution function
main() {
    init_log "$@"

    echo "================================================"
    echo "Ubuntu System Integrity Check and Repair Script"
    echo "Fixed Version - $(date)"
    echo "================================================"
    echo

    if [[ $DRY_RUN -eq 1 ]]; then
        print_status "Running in DRY-RUN mode - no changes will be made"
        echo
    fi

    # Check system requirements
    check_required_commands
    
    # Perform system checks
    print_status "Starting comprehensive system integrity checks..."
    echo
    
    # Update package database (allow failure, continue with other checks)
    if ! update_package_db; then
        print_warning "Package database update failed, but continuing with other checks"
    fi
    
    # Run all system checks
    check_broken_packages
    check_package_integrity || print_warning "Package integrity check could not be completed"
    check_filesystem
    check_system_logs
    check_services
    
    # Perform repairs if needed
    echo
    if [[ $HAS_CORRUPTION -eq 1 ]] || [[ $REPAIR_NEEDED -eq 1 ]]; then
        print_status "Package repair issues detected, performing repairs..."
        repair_packages
    else
        print_success "No corruption or issues detected requiring repair"
    fi
    
    # System cleanup and maintenance
    echo
    print_status "Performing system cleanup and maintenance..."
    cleanup_system
    check_grub
    
    # Print comprehensive summary
    print_summary
    
    # Suggest reboot if repairs were made
    if [[ $REPAIR_SUCCEEDED -eq 1 ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            echo
            print_warning "System repairs were performed. A reboot is recommended."
            print_status "Run 'sudo reboot' when convenient."
        fi
    fi

    echo
    if [[ $HAS_CORRUPTION -eq 1 ]]; then
        print_warning "System integrity check completed with issues detected"
    else
        print_success "System integrity check completed successfully"
    fi
    print_status "Full log available at: $LOG_FILE"
    echo
}

# Set up proper signal handling and cleanup
trap 'echo; print_status "Script interrupted by user"; cleanup' INT TERM
trap 'cleanup' EXIT

# Parse command line arguments before requiring root (allows --help without sudo)
parse_args "$@"

# Validate root privileges
check_root

# Run main function
main "$@"
