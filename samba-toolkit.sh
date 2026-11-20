#!/usr/bin/env bash
# ==============================================================================
# Samba Server Setup and Management Toolkit
# Course: Operating Systems Course Project
# Target OS: Ubuntu Linux (22.04 LTS / 24.04 LTS)
# ==============================================================================
# Description:
#   A safe, modular, menu-driven toolkit to automate setup, configuration,
#   validation, and management of Samba file shares on Ubuntu.
#
# Security & Design Principles:
#   - Explicit root/sudo privilege checks with safe dry-run preview mode.
#   - Timestamped backup of /etc/samba/smb.conf prior to any modification.
#   - Idempotent configuration using unique delimiter markers per managed share.
#   - Atomic syntax validation with `testparm` before applying any config.
#   - Automatic instant rollback if configuration validation fails.
#   - Zero password leakage: passwords fed via stdin to smbpasswd, never logged.
#   - Restrictive directory permissions (no chmod 777; guest access disabled).
#   - Full audit logging to /var/log/samba-toolkit.log or local directory.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Global Constants & Defaults
# ------------------------------------------------------------------------------
readonly TOOLKIT_VERSION="1.0.0"
readonly DEFAULT_SMB_CONF="/etc/samba/smb.conf"
readonly DEFAULT_LOG_FILE="/var/log/samba-toolkit.log"
readonly LOCAL_LOG_FILE="./samba-toolkit.log"
readonly TARGET_UBUNTU_VERSIONS=("20.04" "22.04" "24.04")

# Delimiter markers format:
# # === BEGIN SAMBA-TOOLKIT MANAGED SHARE: [<share_name>] ===
# # === END SAMBA-TOOLKIT MANAGED SHARE: [<share_name>] ===
readonly DELIM_BEGIN_PREFIX="# === BEGIN SAMBA-TOOLKIT MANAGED SHARE: ["
readonly DELIM_END_PREFIX="# === END SAMBA-TOOLKIT MANAGED SHARE: ["

# State variables
SMB_CONF_PATH="${SMB_CONF_OVERRIDE:-$DEFAULT_SMB_CONF}"
DRY_RUN=false
SKIP_OS_CHECK=false
INTERACTIVE=true
TEMP_DIR=""

# Color escape codes (disabled automatically if not attached to a terminal)
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_RED="\033[31m"
    COLOR_GREEN="\033[32m"
    COLOR_YELLOW="\033[33m"
    COLOR_BLUE="\033[34m"
    COLOR_CYAN="\033[36m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_CYAN=""
fi

# ------------------------------------------------------------------------------
# Cleanup and Trap Handling
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Logging Functions
# ------------------------------------------------------------------------------
get_log_destination() {
    if [[ -w "/var/log" ]] || [[ -w "$DEFAULT_LOG_FILE" ]]; then
        echo "$DEFAULT_LOG_FILE"
    else
        echo "$LOCAL_LOG_FILE"
    fi
}

log_msg() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_file
    log_file=$(get_log_destination)

    # Sanitize message to guarantee no passwords or raw credentials leak
    local sanitized_msg
    sanitized_msg=$(printf '%s' "$message" | sed -E 's/(password|passwd|secret)[=:][^ ]+/\1=**REDACTED**/gi')

    if [[ "$DRY_RUN" == true ]]; then
        printf "[DRY-RUN LOG %s] [%s] %s\n" "$timestamp" "$level" "$sanitized_msg" >> "$log_file" 2>/dev/null || true
    else
        printf "[%s] [%s] %s\n" "$timestamp" "$level" "$sanitized_msg" >> "$log_file" 2>/dev/null || true
    fi
}

log_info() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }

# ------------------------------------------------------------------------------
# UI Presentation Helpers
# ------------------------------------------------------------------------------
print_header() {
    printf "\n%b%s%b\n" "${COLOR_BOLD}${COLOR_BLUE}" "================================================================================" "$COLOR_RESET"
    printf "%b  %s%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "$1" "$COLOR_RESET"
    printf "%b%s%b\n" "${COLOR_BOLD}${COLOR_BLUE}" "================================================================================" "$COLOR_RESET"
}

print_info() {
    printf "%b[INFO]%b %s\n" "${COLOR_CYAN}" "${COLOR_RESET}" "$1"
}

print_success() {
    printf "%b[SUCCESS]%b %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$1"
}

print_warning() {
    printf "%b[WARNING]%b %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$1"
}

print_error() {
    printf "%b[ERROR]%b %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$1" >&2
}

print_dry_run() {
    printf "%b[DRY-RUN]%b %s\n" "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" "$1"
}

press_enter_to_continue() {
    if [[ "$INTERACTIVE" == true ]]; then
        printf "\nPress [Enter] to return to the main menu..."
        # shellcheck disable=SC2034
        read -r dummy
    fi
}

confirm_action() {
    local prompt_msg="$1"
    local default_ans="${2:-N}"
    local response

    if [[ "$default_ans" == "Y" ]]; then
        prompt_msg="${prompt_msg} [Y/n]: "
    else
        prompt_msg="${prompt_msg} [y/N]: "
    fi

    printf "%b%s%b" "${COLOR_BOLD}" "$prompt_msg" "${COLOR_RESET}"
    read -r response
    response="${response:-$default_ans}"

    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# System & Environment Checks
# ------------------------------------------------------------------------------
check_ubuntu_version() {
    if [[ "$SKIP_OS_CHECK" == true ]] || [[ "${SAMBA_TOOLKIT_SKIP_OS_CHECK:-0}" == "1" ]]; then
        print_warning "OS verification bypassed via configuration flag."
        log_warn "OS verification bypassed via flag/environment."
        return 0
    fi

    if [[ ! -f "/etc/os-release" ]]; then
        print_error "Cannot verify operating system: /etc/os-release not found."
        print_error "This toolkit requires Ubuntu Linux (e.g., 22.04 LTS or 24.04 LTS)."
        log_error "OS check failed: /etc/os-release missing."
        return 1
    fi

    # Source os-release safely
    local os_id=""
    local os_version=""
    os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    os_version=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

    if [[ "$os_id" != "ubuntu" ]]; then
        print_error "Unsupported operating system: '$os_id'. This toolkit is designed for Ubuntu Linux."
        print_error "Tested on Ubuntu 22.04 LTS (Jammy) and Ubuntu 24.04 LTS (Noble)."
        log_error "OS check failed: System is '$os_id', expected 'ubuntu'."
        return 1
    fi

    local matched=false
    for v in "${TARGET_UBUNTU_VERSIONS[@]}"; do
        if [[ "$os_version" == "$v"* ]]; then
            matched=true
            break
        fi
    done

    if [[ "$matched" == true ]]; then
        print_success "Operating System verified: Ubuntu $os_version."
        log_info "OS verified: Ubuntu $os_version."
        return 0
    else
        print_warning "Ubuntu version detected is $os_version (tested with 22.04 and 24.04 LTS)."
        print_warning "The toolkit will proceed, but test thoroughly."
        log_warn "Non-standard Ubuntu version: $os_version."
        return 0
    fi
}

check_privileges() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Running in Dry-Run mode: root privileges are not required for previewing actions."
        return 0
    fi

    if [[ "$EUID" -ne 0 ]]; then
        print_error "Superuser privileges required."
        print_error "Samba configuration (/etc/samba), service management (systemd), and user credentialing"
        print_error "require administrative access. Please run this script with sudo or as root:"
        print_info "  sudo $0"
        log_error "Privilege check failed: script invoked by EUID $EUID instead of root."
        return 1
    fi

    log_info "Privilege check passed: running with root/sudo authority."
    return 0
}

detect_environment() {
    print_header "System Diagnostics & Privilege Status"
    check_ubuntu_version || {
        if [[ "$DRY_RUN" != true ]]; then
            print_error "Aborting due to OS mismatch. Use --skip-os-check with --dry-run for offline demonstration."
            return 1
        fi
    }

    printf "\n%bPrivilege & Execution Context:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    if [[ "$EUID" -eq 0 ]]; then
        print_success "Effective User: root (UID 0) - privileged actions permitted."
    else
        print_warning "Effective User: UID $EUID (non-root). Real server setup requires sudo."
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Dry-Run mode is ACTIVE. No modifications will be made to files or services."
    fi

    printf "\n%bRequired Tools & Daemon Detection:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    local tools=("testparm" "smbd" "smbpasswd" "systemctl" "ip" "awk" "sed" "grep")
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            printf "  %-14s: %bINSTALLED%b (%s)\n" "$t" "${COLOR_GREEN}" "${COLOR_RESET}" "$(command -v "$t")"
        else
            printf "  %-14s: %bNOT FOUND%b\n" "$t" "${COLOR_RED}" "${COLOR_RESET}"
        fi
    done

    printf "\n%bLog File Location:%b %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$(get_log_destination)"
    printf "%bSamba Config Path:%b %s\n" "${COLOR_BOLD}" "${COLOR_RESET}" "$SMB_CONF_PATH"
}

# ------------------------------------------------------------------------------
# Package Installation
# ------------------------------------------------------------------------------
install_samba() {
    print_header "Install Samba File Server Packages"

    # Check if smbd is already installed
    if command -v smbd >/dev/null 2>&1; then
        local version_str
        version_str=$(smbd -V 2>/dev/null || echo "Unknown version")
        print_info "Samba daemon is already installed: $version_str"
        log_info "Install skipped: Samba already present ($version_str)."
        if ! confirm_action "Do you want to re-run package installation or updates?"; then
            return 0
        fi
    fi

    printf "\n%bPlanned Actions:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    echo "  1. Update APT package index: 'apt-get update'"
    echo "  2. Install packages: samba, samba-common-bin, smbclient"
    echo "  3. Enable and start smbd systemd service"
    echo ""
    print_warning "This action modifies system packages and requires an active internet connection."

    if ! confirm_action "Proceed with Samba package installation?"; then
        print_info "Installation cancelled by user."
        log_info "Samba installation cancelled by user."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would execute: apt-get update"
        print_dry_run "Would execute: apt-get install -y samba samba-common-bin smbclient"
        print_dry_run "Would execute: systemctl enable smbd && systemctl start smbd"
        log_info "[DRY-RUN] Simulated installation of samba, samba-common-bin, smbclient."
        return 0
    fi

    if ! check_privileges; then
        return 1
    fi

    print_info "Updating package lists..."
    log_info "Running: apt-get update"
    if ! apt-get update -y; then
        print_error "apt-get update failed. Check network or package repositories."
        log_error "apt-get update failed."
        return 1
    fi

    print_info "Installing Samba packages..."
    log_info "Running: apt-get install -y samba samba-common-bin smbclient"
    if ! apt-get install -y samba samba-common-bin smbclient; then
        print_error "Failed to install Samba packages."
        log_error "apt-get install samba failed."
        return 1
    fi

    print_info "Enabling and starting smbd daemon..."
    systemctl enable smbd || true
    systemctl start smbd || true

    print_success "Samba packages installed and service initialized successfully."
    log_info "Samba packages installed and service initialized."
}

# ------------------------------------------------------------------------------
# Configuration Backup & Safe Modification
# ------------------------------------------------------------------------------
create_config_backup() {
    local source_conf="$1"
    if [[ ! -f "$source_conf" ]]; then
        print_warning "Source configuration '$source_conf' does not exist yet. No backup created."
        return 0
    fi

    local timestamp
    timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_path="${source_conf}.bak.${timestamp}"

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would backup '$source_conf' to '$backup_path'"
        echo "$backup_path"
        return 0
    fi

    if cp -p "$source_conf" "$backup_path"; then
        print_success "Timestamped backup created: $backup_path"
        log_info "Backup created: $backup_path"
        echo "$backup_path"
        return 0
    else
        print_error "Failed to create backup of $source_conf."
        log_error "Backup creation failed for $source_conf."
        return 1
    fi
}

restore_config_backup() {
    local backup_path="$1"
    local target_conf="$2"

    if [[ -z "$backup_path" || ! -f "$backup_path" ]]; then
        print_error "Cannot restore: backup file '$backup_path' not found."
        log_error "Restore aborted: backup '$backup_path' missing."
        return 1
    fi

    print_warning "Restoring configuration from backup: $backup_path -> $target_conf"
    if cp -p "$backup_path" "$target_conf"; then
        print_success "Configuration restored successfully from backup."
        log_info "Configuration restored from: $backup_path."
        return 0
    else
        print_error "CRITICAL: Failed to restore backup $backup_path."
        log_error "CRITICAL: Restore failed for $backup_path."
        return 1
    fi
}

validate_with_testparm() {
    local conf_to_test="$1"

    if ! command -v testparm >/dev/null 2>&1; then
        print_error "Validation utility 'testparm' not found in PATH."
        return 1
    fi

    print_info "Validating configuration with 'testparm -s'..."
    local testparm_output
    if testparm_output=$(testparm -s "$conf_to_test" 2>&1); then
        print_success "Syntax validation PASSED by testparm."
        log_info "testparm validation passed for $conf_to_test."
        return 0
    else
        print_error "Configuration validation FAILED by testparm."
        printf "\n%btestparm error output:%b\n%s\n\n" "${COLOR_RED}" "${COLOR_RESET}" "$testparm_output"
        log_error "testparm validation failed: $testparm_output"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Input Validation Helpers
# ------------------------------------------------------------------------------
validate_share_name() {
    local name="$1"
    # Strict alphanumeric with underscore and hyphen, 1-30 chars
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]{1,30}$ ]]; then
        print_error "Invalid share name '$name'."
        print_error "Share names must be 1-30 characters and contain only letters, numbers, underscores, or hyphens."
        return 1
    fi

    # Disallow reserved Samba sections
    local lower_name
    lower_name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_name" == "global" || "$lower_name" == "homes" || "$lower_name" == "printers" || "$lower_name" == "print$" || "$lower_name" == "ipc$" ]]; then
        print_error "Share name '$name' is a reserved Samba keyword."
        return 1
    fi

    return 0
}

validate_share_path() {
    local p="$1"
    if [[ ! "$p" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
        print_error "Invalid share path '$p'. Must be an absolute path starting with /."
        return 1
    fi

    # Disallow dangerous root/system directories
    case "$p" in
        /|/etc|/etc/*|/bin|/sbin|/usr|/usr/bin|/usr/sbin|/boot|/dev|/proc|/sys|/lib|/lib64|/root)
            print_error "Path '$p' is a sensitive system directory and cannot be used as a Samba share."
            return 1
            ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
# Share Management: Create / Update Share
# ------------------------------------------------------------------------------
create_or_update_share() {
    print_header "Create / Update Password-Protected Samba Share"

    if ! check_privileges; then
        if [[ "$DRY_RUN" != true ]]; then
            return 1
        fi
    fi

    # 1. Share Name
    local share_name=""
    while true; do
        printf "%bEnter Share Name%b (e.g., os_project_share): " "${COLOR_BOLD}" "${COLOR_RESET}"
        read -r share_name
        if validate_share_name "$share_name"; then
            break
        fi
    done

    # 2. Share Directory Path
    local default_path="/srv/samba/${share_name}"
    local share_path=""
    while true; do
        printf "%bEnter Directory Path%b [default: %s]: " "${COLOR_BOLD}" "${COLOR_RESET}" "$default_path"
        read -r share_path
        share_path="${share_path:-$default_path}"
        if validate_share_path "$share_path"; then
            break
        fi
    done

    # 3. Existing Linux Username
    local share_user=""
    while true; do
        printf "%bEnter Existing Linux Username%b to grant access: " "${COLOR_BOLD}" "${COLOR_RESET}"
        read -r share_user
        if [[ -z "$share_user" ]]; then
            print_error "Username cannot be empty."
            continue
        fi

        if id "$share_user" >/dev/null 2>&1; then
            print_success "Verified local Linux user: $share_user (UID: $(id -u "$share_user"))."
            break
        else
            print_warning "Linux user '$share_user' does not exist on this system."
            if confirm_action "Would you like to create system user '$share_user' now (no login shell)?"; then
                if [[ "$DRY_RUN" == true ]]; then
                    print_dry_run "Would execute: useradd -M -s /usr/sbin/nologin $share_user"
                    break
                else
                    if useradd -M -s /usr/sbin/nologin "$share_user"; then
                        print_success "Created system user '$share_user'."
                        log_info "Created system user '$share_user' for Samba share."
                        break
                    else
                        print_error "Failed to create user '$share_user'."
                    fi
                fi
            fi
        fi
    done

    # 4. Access Permissions: Read-Write or Read-Only
    local read_only="no"
    if confirm_action "Should this share be Read-Only? (No = Read & Write)" "N"; then
        read_only="yes"
    fi

    # 5. Comment / Description
    printf "%bEnter Share Description%b [default: %s]: " "${COLOR_BOLD}" "${COLOR_RESET}" "Managed Share for $share_user"
    local share_comment=""
    read -r share_comment
    share_comment="${share_comment:-Managed Share for $share_user}"

    # 6. Samba Password Configuration
    printf "\n%bSamba Password Configuration for user '%s':%b\n" "${COLOR_BOLD}" "$share_user" "${COLOR_RESET}"
    print_info "Note: Samba maintains its own password database via smbpasswd."
    local smb_pass=""
    local smb_pass_confirm=""

    while true; do
        printf "Enter Samba Password for '%s': " "$share_user"
        read -r -s smb_pass
        echo ""
        if [[ -z "$smb_pass" ]]; then
            print_error "Password cannot be empty. Please try again."
            continue
        fi

        printf "Confirm Samba Password: "
        read -r -s smb_pass_confirm
        echo ""

        if [[ "$smb_pass" != "$smb_pass_confirm" ]]; then
            print_error "Passwords do not match. Please re-enter."
            smb_pass=""
            smb_pass_confirm=""
            continue
        fi
        break
    done

    # 7. Review Planned Configuration
    printf "\n%b================ Planned Share Summary ===============%b\n" "${COLOR_CYAN}" "${COLOR_RESET}"
    echo "  Share Name       : [$share_name]"
    echo "  Directory Path   : $share_path"
    echo "  Authorized User  : $share_user"
    echo "  Access Level     : $( [[ "$read_only" == "yes" ]] && echo "Read-Only" || echo "Read-Write" )"
    echo "  Guest Access     : Disabled (Strict Authentication Required)"
    echo "  Directory Perms  : 2770 (Owner & Group read/write/execute, others denied)"
    echo "  File Create Mask : 0660 (Restrictive, no world-accessible files)"
    echo "  Target Config    : $SMB_CONF_PATH"
    printf "%b======================================================%b\n\n" "${COLOR_CYAN}" "${COLOR_RESET}"

    if ! confirm_action "Apply this configuration now?"; then
        print_info "Operation cancelled by user."
        unset smb_pass smb_pass_confirm
        return 0
    fi

    # --------------------------------------------------------------------------
    # Dry-Run Execution Branch
    # --------------------------------------------------------------------------
    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would ensure directory exists: mkdir -p $share_path"
        print_dry_run "Would set ownership: chown $share_user:$share_user $share_path"
        print_dry_run "Would set restrictive permissions: chmod 2770 $share_path"
        print_dry_run "Would set Samba password via: printf '***\\n***\\n' | smbpasswd -s -a $share_user"
        print_dry_run "Would create backup of $SMB_CONF_PATH"
        print_dry_run "Would insert managed block for [$share_name] into $SMB_CONF_PATH"
        print_dry_run "Would validate new config using testparm -s"
        print_dry_run "Would reload/restart smbd service: systemctl reload smbd"
        unset smb_pass smb_pass_confirm
        log_info "[DRY-RUN] Simulated share configuration for [$share_name] at $share_path."
        return 0
    fi

    # --------------------------------------------------------------------------
    # Real Execution: Step 1: Directory Setup & Permissions
    # --------------------------------------------------------------------------
    print_info "Ensuring shared directory exists with restrictive permissions..."
    if ! mkdir -p "$share_path"; then
        print_error "Failed to create directory $share_path."
        unset smb_pass smb_pass_confirm
        return 1
    fi

    # Enforce safe permissions: 2770 (setgid ensures group inheritance, 0 access to others)
    # Never chmod 777!
    chown "$share_user":"$share_user" "$share_path"
    chmod 2770 "$share_path"
    print_success "Directory permissions set to 2770 (owner/group: $share_user, others: no access)."

    # --------------------------------------------------------------------------
    # Real Execution: Step 2: Set Samba Password via smbpasswd
    # --------------------------------------------------------------------------
    print_info "Configuring Samba password for user '$share_user'..."
    # Pipe directly to smbpasswd -s -a to avoid history, logs, and ps arguments
    if printf "%s\n%s\n" "$smb_pass" "$smb_pass" | smbpasswd -s -a "$share_user" >/dev/null 2>&1; then
        print_success "Samba password updated successfully for '$share_user'."
        log_info "Samba credentials updated for user '$share_user'."
    else
        # If user was already in smbpasswd, try without -a
        if printf "%s\n%s\n" "$smb_pass" "$smb_pass" | smbpasswd -s "$share_user" >/dev/null 2>&1; then
            print_success "Samba password updated successfully for '$share_user'."
            log_info "Samba credentials updated for user '$share_user'."
        else
            print_error "Failed to update Samba password with smbpasswd."
            log_error "smbpasswd execution failed for '$share_user'."
            unset smb_pass smb_pass_confirm
            return 1
        fi
    fi
    # Wipe password from memory immediately
    unset smb_pass smb_pass_confirm

    # --------------------------------------------------------------------------
    # Real Execution: Step 3: Backup Existing smb.conf
    # --------------------------------------------------------------------------
    local backup_file
    backup_file=$(create_config_backup "$SMB_CONF_PATH")

    # --------------------------------------------------------------------------
    # Real Execution: Step 4: Generate Configuration Block
    # --------------------------------------------------------------------------
    TEMP_DIR=$(mktemp -d)
    local staged_conf="${TEMP_DIR}/smb.conf.staged"
    local managed_block="${TEMP_DIR}/managed_share.block"

    cat <<EOF > "$managed_block"
${DELIM_BEGIN_PREFIX}${share_name}] ===
[${share_name}]
    comment = ${share_comment}
    path = ${share_path}
    valid users = ${share_user}
    read only = ${read_only}
    browsable = yes
    guest ok = no
    create mask = 0660
    directory mask = 0770
${DELIM_END_PREFIX}${share_name}] ===
EOF

    # If smb.conf does not exist, initialize with a safe global section
    if [[ ! -f "$SMB_CONF_PATH" ]]; then
        print_warning "Samba config $SMB_CONF_PATH not found. Initializing with default [global] section."
        cat <<EOF > "$staged_conf"
# Default Samba Configuration generated by Samba Server Toolkit
[global]
    workgroup = WORKGROUP
    server string = Samba File Server
    server role = standalone server
    obey pam restrictions = yes
    unix password sync = yes
    pam password change = yes
    map to guest = bad user
    usershare allow guests = no
    log file = /var/log/samba/log.%m
    max log size = 1000

EOF
        cat "$managed_block" >> "$staged_conf"
    else
        # Idempotently update or append the share section
        # Remove any existing block for this specific share name first
        local begin_marker="${DELIM_BEGIN_PREFIX}${share_name}] ==="
        local end_marker="${DELIM_END_PREFIX}${share_name}] ==="

        # Use awk to strip existing block if present, preserving everything else
        awk -v b="$begin_marker" -v e="$end_marker" '
            $0 == b { in_block = 1; next }
            $0 == e { in_block = 0; next }
            !in_block { print }
        ' "$SMB_CONF_PATH" > "$staged_conf"

        # Append new managed block
        printf "\n" >> "$staged_conf"
        cat "$managed_block" >> "$staged_conf"
    fi

    # --------------------------------------------------------------------------
    # Real Execution: Step 5: Validate with testparm
    # --------------------------------------------------------------------------
    if ! validate_with_testparm "$staged_conf"; then
        print_error "New configuration is INVALID according to testparm."
        print_error "Aborting modification. Restoring previous configuration..."
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            restore_config_backup "$backup_file" "$SMB_CONF_PATH"
        fi
        log_error "Configuration modification aborted for [$share_name] due to validation failure."
        return 1
    fi

    # --------------------------------------------------------------------------
    # Real Execution: Step 6: Atomically Apply Config
    # --------------------------------------------------------------------------
    print_info "Applying validated configuration to $SMB_CONF_PATH..."
    if cp "$staged_conf" "$SMB_CONF_PATH"; then
        chmod 0644 "$SMB_CONF_PATH"
        print_success "Configuration updated successfully."
        log_info "Share [$share_name] successfully configured in $SMB_CONF_PATH."
    else
        print_error "Failed to copy staged configuration to $SMB_CONF_PATH."
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            restore_config_backup "$backup_file" "$SMB_CONF_PATH"
        fi
        return 1
    fi

    # --------------------------------------------------------------------------
    # Real Execution: Step 7: Reload / Restart Service
    # --------------------------------------------------------------------------
    reload_samba_service
    show_connection_instructions "$share_name" "$share_user"
}

# ------------------------------------------------------------------------------
# Service Management
# ------------------------------------------------------------------------------
reload_samba_service() {
    print_info "Checking Samba daemon service status..."
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warning "'systemctl' not available. Skipping automatic service reload."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would execute: systemctl reload-or-restart smbd"
        return 0
    fi

    if systemctl is-active --quiet smbd 2>/dev/null; then
        print_info "Reloading smbd service to activate new configuration..."
        if systemctl reload-or-restart smbd; then
            print_success "smbd service reloaded successfully."
            log_info "smbd service reloaded."
        else
            print_error "Failed to reload smbd service."
            log_error "systemctl reload-or-restart smbd failed."
        fi
    else
        print_info "Starting smbd service..."
        if systemctl start smbd; then
            print_success "smbd service started successfully."
            log_info "smbd service started."
        else
            print_error "Failed to start smbd service. Check system logs: journalctl -u smbd"
            log_error "systemctl start smbd failed."
        fi
    fi
}

restart_samba_service() {
    print_info "Restarting smbd service to terminate active client worker processes..."
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warning "'systemctl' not available. Skipping automatic service restart."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would execute: systemctl restart smbd"
        return 0
    fi

    if systemctl restart smbd; then
        print_success "smbd service restarted. All active client sessions terminated."
        log_info "smbd service restarted (active client sessions severed)."
    else
        print_error "Failed to restart smbd service."
        log_error "systemctl restart smbd failed."
    fi
}

stop_samba_service() {
    print_info "Stopping Samba daemon services (smbd & nmbd)..."
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warning "'systemctl' not available. Skipping automatic service stop."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would execute: systemctl stop smbd nmbd"
        log_info "[DRY-RUN] Simulated stop of Samba services."
        return 0
    fi

    local stopped_any=false
    for svc in "smbd" "nmbd"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            if systemctl stop "$svc" 2>/dev/null; then
                stopped_any=true
            fi
        fi
    done

    if [[ "$stopped_any" == true ]]; then
        print_success "Samba services stopped successfully."
        log_info "Samba services stopped."
    else
        print_info "Samba services were not currently running."
    fi
}

start_samba_service() {
    print_info "Starting Samba daemon services..."
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warning "'systemctl' not available. Skipping service start."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would execute: systemctl start smbd"
        return 0
    fi

    if systemctl start smbd; then
        print_success "smbd service started successfully."
        log_info "smbd service started."
    else
        print_error "Failed to start smbd service. Check logs: journalctl -u smbd"
        log_error "systemctl start smbd failed."
        return 1
    fi
}

manage_service_menu() {
    print_header "Samba Service Control"
    echo "  [1] Start Samba (smbd)"
    echo "  [2] Stop Samba (smbd & nmbd)"
    echo "  [3] Restart Samba (sever all active sessions)"
    echo "  [4] Reload Samba configuration"
    echo "  [0] Back to Main Menu"

    local s_choice
    printf "\nEnter choice [0-4]: "
    read -r s_choice
    case "$s_choice" in
        1) start_samba_service ;;
        2) stop_samba_service ;;
        3) restart_samba_service ;;
        4) reload_samba_service ;;
        *) print_info "No changes made." ;;
    esac
}

check_service_status() {
    print_header "Samba Service & Process Status"
    if ! command -v systemctl >/dev/null 2>&1; then
        print_warning "systemctl not found. Checking processes via ps:"
        ps aux | grep -E '[s]mbd|[n]mbd' || echo "No active Samba processes found."
        return 0
    fi

    printf "%bService Active Status:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    local services=("smbd" "nmbd")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  %-10s: %bRUNNING (active)%b\n" "$svc" "${COLOR_GREEN}" "${COLOR_RESET}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            printf "  %-10s: %bINACTIVE (enabled)%b\n" "$svc" "${COLOR_YELLOW}" "${COLOR_RESET}"
        else
            printf "  %-10s: %bSTOPPED / NOT FOUND%b\n" "$svc" "${COLOR_RED}" "${COLOR_RESET}"
        fi
    done

    if command -v smbstatus >/dev/null 2>&1; then
        printf "\n%bActive Client Connections & Open Shares (smbstatus):%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
        smbstatus --shares 2>/dev/null || smbstatus -S 2>/dev/null || print_info "No active client connections."
    fi

    printf "\n%bRecent Systemd Journal Entries for smbd:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    journalctl -u smbd --no-pager -n 10 2>/dev/null || print_warning "Could not read journalctl logs (requires sudo/adm group)."
}

# ------------------------------------------------------------------------------
# Share Management: List Managed Shares
# ------------------------------------------------------------------------------
list_managed_shares() {
    print_header "Samba Shares Managed by Toolkit"

    if [[ ! -f "$SMB_CONF_PATH" ]]; then
        print_warning "Samba configuration file '$SMB_CONF_PATH' not found."
        return 0
    fi

    # Extract all share blocks between managed markers
    local share_names=()
    while IFS= read -r line; do
        if [[ "$line" == "${DELIM_BEGIN_PREFIX}"* ]]; then
            local temp="${line#"${DELIM_BEGIN_PREFIX}"}"
            local sname="${temp%%\]*}"
            [[ -n "$sname" ]] && share_names+=("$sname")
        fi
    done < "$SMB_CONF_PATH"

    if [[ ${#share_names[@]} -eq 0 ]]; then
        print_info "No toolkit-managed shares found in $SMB_CONF_PATH."
        print_info "Existing unmanaged shares and [global] configuration remain untouched."
        return 0
    fi

    printf "%bFound %d managed share(s):%b\n\n" "${COLOR_GREEN}" "${#share_names[@]}" "${COLOR_RESET}"
    printf "%b%-20s %-30s %-15s %-10s%b\n" "${COLOR_BOLD}" "SHARE NAME" "PATH" "VALID USER" "READ ONLY" "${COLOR_RESET}"
    printf "%s\n" "--------------------------------------------------------------------------------"

    for name in "${share_names[@]}"; do
        local begin_marker="${DELIM_BEGIN_PREFIX}${name}] ==="
        local end_marker="${DELIM_END_PREFIX}${name}] ==="

        local block
        block=$(awk -v b="$begin_marker" -v e="$end_marker" '
            $0 == b { in_block = 1; next }
            $0 == e { in_block = 0; next }
            in_block { print }
        ' "$SMB_CONF_PATH")

        local path val_user ro
        path=$(echo "$block" | grep -E '^[[:space:]]*path[[:space:]]*=' | head -n1 | cut -d= -f2- | tr -d ' ')
        val_user=$(echo "$block" | grep -E '^[[:space:]]*valid users[[:space:]]*=' | head -n1 | cut -d= -f2- | tr -d ' ')
        ro=$(echo "$block" | grep -E '^[[:space:]]*read only[[:space:]]*=' | head -n1 | cut -d= -f2- | tr -d ' ')

        printf "%-20s %-30s %-15s %-10s\n" "[$name]" "${path:-N/A}" "${val_user:-N/A}" "${ro:-no}"
    done
    printf "%s\n" "--------------------------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# Share Management: Remove Share
# ------------------------------------------------------------------------------
remove_managed_share() {
    print_header "Remove Toolkit-Managed Samba Share"

    if ! check_privileges; then
        if [[ "$DRY_RUN" != true ]]; then
            return 1
        fi
    fi

    if [[ ! -f "$SMB_CONF_PATH" ]]; then
        print_error "Configuration file $SMB_CONF_PATH does not exist."
        return 1
    fi

    # Discover managed shares
    local share_names=()
    while IFS= read -r line; do
        if [[ "$line" == "${DELIM_BEGIN_PREFIX}"* ]]; then
            local temp="${line#"${DELIM_BEGIN_PREFIX}"}"
            local sname="${temp%%\]*}"
            [[ -n "$sname" ]] && share_names+=("$sname")
        fi
    done < "$SMB_CONF_PATH"

    if [[ ${#share_names[@]} -eq 0 ]]; then
        print_warning "No toolkit-managed shares available to remove."
        return 0
    fi

    echo "Select a managed share to remove:"
    for i in "${!share_names[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "${share_names[$i]}"
    done
    echo "  [0] Cancel"

    local choice
    printf "\nEnter selection [0-%d]: " "${#share_names[@]}"
    read -r choice

    if [[ "$choice" == "0" || ! "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice > ${#share_names[@]} )); then
        print_info "Removal cancelled."
        return 0
    fi

    local target_share="${share_names[$((choice - 1))]}"
    local begin_marker="${DELIM_BEGIN_PREFIX}${target_share}] ==="
    local end_marker="${DELIM_END_PREFIX}${target_share}] ==="

    # Extract target share path
    local block
    block=$(awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { in_block = 1; next }
        $0 == e { in_block = 0; next }
        in_block { print }
    ' "$SMB_CONF_PATH")
    local share_path
    share_path=$(echo "$block" | grep -E '^[[:space:]]*path[[:space:]]*=' | head -n1 | cut -d= -f2- | tr -d ' ')

    printf "\n%bRemoval Impact Assessment:%b\n" "${COLOR_BOLD}${COLOR_RED}" "${COLOR_RESET}"
    echo "  - The configuration block for '[$target_share]' will be excised from $SMB_CONF_PATH."
    echo "  - All other shares and [global] settings will be preserved untouched."
    echo "  - A timestamped backup will be created prior to alteration."
    echo "  - The resulting configuration will be validated with testparm."
    echo "  - smbd service will be reloaded."
    echo "  - Associated directory: ${share_path:-Unknown}"
    echo ""

    if ! confirm_action "Are you sure you want to remove share '[$target_share]' from Samba configuration?"; then
        print_info "Removal cancelled."
        return 0
    fi

    # Option to keep or remove directory
    local remove_dir=false
    if [[ -n "$share_path" && -d "$share_path" ]]; then
        print_warning "Shared directory exists: $share_path"
        print_warning "DEFAULT (SAFE): Keep the directory and all existing files on disk."
        if confirm_action "Do you also wish to PERMANENTLY DELETE the shared directory and files?" "N"; then
            printf "%bType 'DELETE' to confirm permanent folder removal: %b" "${COLOR_RED}${COLOR_BOLD}" "${COLOR_RESET}"
            local delete_confirm
            read -r delete_confirm
            if [[ "$delete_confirm" == "DELETE" ]]; then
                remove_dir=true
                print_warning "Directory will be deleted."
            else
                print_info "Confirmation mismatched. Directory will be KEPT intact."
            fi
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would backup $SMB_CONF_PATH"
        print_dry_run "Would remove section for [$target_share] from $SMB_CONF_PATH"
        print_dry_run "Would run testparm -s"
        print_dry_run "Would reload smbd service"
        if [[ "$remove_dir" == true ]]; then
            print_dry_run "Would execute: rm -rf $share_path"
        fi
        log_info "[DRY-RUN] Simulated removal of share [$target_share]."
        return 0
    fi

    # Backup before modification
    local backup_file
    backup_file=$(create_config_backup "$SMB_CONF_PATH")

    TEMP_DIR=$(mktemp -d)
    local staged_conf="${TEMP_DIR}/smb.conf.staged"

    # Strip the target share block
    awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { in_block = 1; next }
        $0 == e { in_block = 0; next }
        !in_block { print }
    ' "$SMB_CONF_PATH" > "$staged_conf"

    if ! validate_with_testparm "$staged_conf"; then
        print_error "Configuration invalid after share removal! Restoring backup..."
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            restore_config_backup "$backup_file" "$SMB_CONF_PATH"
        fi
        return 1
    fi

    if cp "$staged_conf" "$SMB_CONF_PATH"; then
        print_success "Share '[$target_share]' removed from $SMB_CONF_PATH."
        log_info "Share '[$target_share]' excised from $SMB_CONF_PATH."
    else
        print_error "Failed to save updated configuration."
        restore_config_backup "$backup_file" "$SMB_CONF_PATH"
        return 1
    fi

    if [[ "$remove_dir" == true && -n "$share_path" && -d "$share_path" ]]; then
        print_info "Deleting directory $share_path..."
        rm -rf "$share_path"
        print_success "Directory $share_path deleted."
        log_info "Directory $share_path deleted upon user request."
    fi

    # Terminate active client connections to this specific share if smbcontrol is available
    if command -v smbcontrol >/dev/null 2>&1 && [[ "$DRY_RUN" != true ]]; then
        print_info "Signaling smbd to close active client connections for '[$target_share]'..."
        smbcontrol smbd close-share "$target_share" 2>/dev/null || true
    fi

    # Restart or reload service
    printf "\n%bSession Disconnection Option:%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    echo "  Reloading allows existing active client sessions to linger until unmounted."
    echo "  Restarting immediately severs all active connections across the server."
    if confirm_action "Restart smbd to forcefully terminate active client sessions immediately?" "Y"; then
        restart_samba_service
    else
        reload_samba_service
    fi

    printf "\n%bClient-Side Disconnection Guidance:%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "${COLOR_RESET}"
    echo "  Operating systems (Windows & macOS) aggressively cache open SMB sessions and folder handles."
    echo "  Even after server removal, a connected client may show cached contents until disconnected:"
    echo "    - Windows: Run in CMD -> 'net use \\\\<server>\\$target_share /delete'"
    echo "               (or 'net use * /delete /y' to disconnect all cached sessions)"
    echo "    - macOS:   In Finder, click the Eject icon next to the share in the sidebar,"
    echo "               or in Terminal run -> 'umount /Volumes/$target_share'"
    echo "    - Linux:   Run -> 'sudo umount <mount_point>'"
}

# ------------------------------------------------------------------------------
# Network Discovery & Client Connection Instructions
# ------------------------------------------------------------------------------
get_server_ips() {
    local ip_list=()
    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r ip_entry; do
            [[ -n "$ip_entry" ]] && ip_list+=("$ip_entry")
        done < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
    elif command -v hostname >/dev/null 2>&1; then
        while IFS= read -r ip_entry; do
            [[ -n "$ip_entry" ]] && ip_list+=("$ip_entry")
        done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$')
    fi

    if [[ ${#ip_list[@]} -eq 0 ]]; then
        echo "127.0.0.1"
    else
        printf "%s\n" "${ip_list[@]}"
    fi
}

show_connection_instructions() {
    local share_name="${1:-<share_name>}"
    local user="${2:-<username>}"

    print_header "Client Connection Instructions"

    local ip_addresses=()
    while IFS= read -r ip_line; do
        [[ -n "$ip_line" ]] && ip_addresses+=("$ip_line")
    done < <(get_server_ips)

    local primary_ip="${ip_addresses[0]:-127.0.0.1}"

    printf "%bDetected Server IP Address(es):%b\n" "${COLOR_BOLD}" "${COLOR_RESET}"
    for ip in "${ip_addresses[@]}"; do
        printf "  - %b%s%b\n" "${COLOR_GREEN}" "$ip" "${COLOR_RESET}"
    done

    printf "\n%b1. Windows Clients (File Explorer or CMD):%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "${COLOR_RESET}"
    echo "   File Explorer Address Bar:"
    printf "     %b%s%b\n" "${COLOR_YELLOW}" "\\\\${primary_ip}\\${share_name}" "${COLOR_RESET}"
    echo "   Command Prompt / PowerShell (Map to Network Drive Z:):"
    printf "     %b%s%b\n" "${COLOR_YELLOW}" "net use Z: \\\\${primary_ip}\\${share_name} /user:${user} *" "${COLOR_RESET}"

    printf "\n%b2. macOS Clients (Finder):%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "${COLOR_RESET}"
    echo "   Press [Command + K] in Finder and enter:"
    printf "     %bsmb://%s@%s/%s%b\n" "${COLOR_YELLOW}" "$user" "$primary_ip" "$share_name" "${COLOR_RESET}"

    printf "\n%b3. Linux Clients:%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "${COLOR_RESET}"
    echo "   Command Line Testing (smbclient):"
    printf "     %bsmbclient //%s/%s -U %s%b\n" "${COLOR_YELLOW}" "$primary_ip" "$share_name" "$user" "${COLOR_RESET}"
    echo "   Mount CIFS Share:"
    printf "     %bsudo mount -t cifs //%s/%s /mnt -o username=%s%b\n" "${COLOR_YELLOW}" "$primary_ip" "$share_name" "$user" "${COLOR_RESET}"

    printf "\n%b4. Firewall Note (Ubuntu UFW):%b\n" "${COLOR_BOLD}${COLOR_CYAN}" "${COLOR_RESET}"
    echo "   If client cannot connect, allow Samba through the firewall:"
    printf "     %bsudo ufw allow samba%b  (Ports: 137,138/udp and 139,445/tcp)\n" "${COLOR_YELLOW}" "${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Configuration Testing & Audit Logs
# ------------------------------------------------------------------------------
test_configuration_menu() {
    print_header "Test Samba Configuration"
    if [[ ! -f "$SMB_CONF_PATH" ]]; then
        print_error "Configuration file $SMB_CONF_PATH does not exist."
        return 1
    fi

    validate_with_testparm "$SMB_CONF_PATH"
}

view_audit_log() {
    print_header "Project Audit Log"
    local log_file
    log_file=$(get_log_destination)

    if [[ ! -f "$log_file" ]]; then
        print_info "Log file '$log_file' does not exist yet."
        return 0
    fi

    printf "%bDisplaying last 25 lines of %s:%b\n\n" "${COLOR_BOLD}" "$log_file" "${COLOR_RESET}"
    tail -n 25 "$log_file"
}

# ------------------------------------------------------------------------------
# Help and CLI Usage
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
Samba Server Setup and Management Toolkit v${TOOLKIT_VERSION}
Operating Systems Course Project

Usage:
  sudo ./samba-toolkit.sh [OPTIONS]

Options:
  -d, --dry-run          Simulate execution without modifying files, installing packages,
                         or changing services. Safe for demonstration and verification.
  --skip-os-check        Bypass the Ubuntu OS distribution check (useful for offline syntax
                         or dry-run verification on non-Ubuntu developer workstations).
  -c, --config PATH      Specify alternate smb.conf path (defaults to /etc/samba/smb.conf).
  -h, --help             Display this help message and exit.
  -v, --version          Display version information and exit.

Non-Interactive Commands:
  --status               Show Samba service status and exit.
  --start                Start Samba services and exit.
  --stop                 Stop Samba services (smbd & nmbd) and exit.
  --restart              Restart Samba services and exit.
  --list                 List managed shares and exit.
  --validate             Run testparm validation on current config and exit.
  --info                 Display IP addresses and client connection guide and exit.

EOF
}

# ------------------------------------------------------------------------------
# Main Interactive Menu
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || printf "\033[2J\033[H"
        print_header "Samba Server Setup and Management Toolkit (v${TOOLKIT_VERSION})"
        echo " Course: Operating Systems Project | Target: Ubuntu 22.04 / 24.04 LTS"
        if [[ "$DRY_RUN" == true ]]; then
            printf " %bMODE: [DRY-RUN / PREVIEW ONLY - NO SYSTEM CHANGES]%b\n" "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}"
        else
            printf " %bMODE: [LIVE EXECUTION]%b (EUID: %d)\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$EUID"
        fi
        echo " Config File: $SMB_CONF_PATH"
        echo "================================================================================"
        echo "  [1] System Diagnostics & Environment Check"
        echo "  [2] Install / Verify Samba Packages"
        echo "  [3] Create or Update Password-Protected Share"
        echo "  [4] List Managed Shares & Settings"
        echo "  [5] Validate Configuration (testparm)"
        echo "  [6] Check Samba Service Status"
        echo "  [7] Remove a Managed Share"
        echo "  [8] Client Connection Instructions & IP Addresses"
        echo "  [9] View Audit Log"
        echo "  [S] Start / Stop / Restart Samba Service"
        echo "  [T] Toggle Dry-Run Mode ($( [[ "$DRY_RUN" == true ]] && echo "Enabled" || echo "Disabled" ))"
        echo "  [0] Exit Toolkit (Option to stop Samba on exit)"
        echo "================================================================================"

        local choice
        printf "%bEnter your choice [0-9, S, T]: %b" "${COLOR_BOLD}" "${COLOR_RESET}"
        read -r choice

        case "$choice" in
            1)
                detect_environment
                press_enter_to_continue
                ;;
            2)
                install_samba
                press_enter_to_continue
                ;;
            3)
                create_or_update_share
                press_enter_to_continue
                ;;
            4)
                list_managed_shares
                press_enter_to_continue
                ;;
            5)
                test_configuration_menu
                press_enter_to_continue
                ;;
            6)
                check_service_status
                press_enter_to_continue
                ;;
            7)
                remove_managed_share
                press_enter_to_continue
                ;;
            8)
                show_connection_instructions
                press_enter_to_continue
                ;;
            9)
                view_audit_log
                press_enter_to_continue
                ;;
            [sS])
                manage_service_menu
                press_enter_to_continue
                ;;
            [tT])
                if [[ "$DRY_RUN" == true ]]; then
                    DRY_RUN=false
                    print_info "Dry-Run mode disabled. Live changes will take effect."
                else
                    DRY_RUN=true
                    print_warning "Dry-Run mode enabled. Changes will be simulated."
                fi
                press_enter_to_continue
                ;;
            0|[qQ])
                # Offer to stop Samba daemon on exit if active
                if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet smbd 2>/dev/null; then
                    printf "\n%bSamba daemon is currently running.%b\n" "${COLOR_YELLOW}" "${COLOR_RESET}"
                    if confirm_action "Would you like to stop the Samba service before exiting?" "Y"; then
                        stop_samba_service
                    else
                        print_info "Leaving Samba service running in the background."
                    fi
                elif [[ "$DRY_RUN" == true ]]; then
                    printf "\n%b[DRY-RUN] Samba daemon would be checked on exit.%b\n" "${COLOR_YELLOW}" "${COLOR_RESET}"
                    if confirm_action "Would you like to stop the Samba service before exiting?" "Y"; then
                        stop_samba_service
                    fi
                fi
                print_info "Exiting Samba Management Toolkit. Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid selection. Please choose an option from the menu."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entry Point & CLI Parsing
# ------------------------------------------------------------------------------
main() {
    local cmd_action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-os-check)
                SKIP_OS_CHECK=true
                shift
                ;;
            -c|--config)
                if [[ -n "${2:-}" ]]; then
                    SMB_CONF_PATH="$2"
                    shift 2
                else
                    print_error "--config requires a file path argument."
                    exit 1
                fi
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "Samba Server Setup and Management Toolkit v${TOOLKIT_VERSION}"
                exit 0
                ;;
            --status)
                cmd_action="status"
                INTERACTIVE=false
                shift
                ;;
            --start)
                cmd_action="start"
                INTERACTIVE=false
                shift
                ;;
            --stop)
                cmd_action="stop"
                INTERACTIVE=false
                shift
                ;;
            --restart)
                cmd_action="restart"
                INTERACTIVE=false
                shift
                ;;
            --list)
                cmd_action="list"
                INTERACTIVE=false
                shift
                ;;
            --validate)
                cmd_action="validate"
                INTERACTIVE=false
                shift
                ;;
            --info)
                cmd_action="info"
                INTERACTIVE=false
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Execute non-interactive subcommands if requested
    case "$cmd_action" in
        status)
            check_service_status
            exit 0
            ;;
        start)
            start_samba_service
            exit 0
            ;;
        stop)
            stop_samba_service
            exit 0
            ;;
        restart)
            restart_samba_service
            exit 0
            ;;
        list)
            list_managed_shares
            exit 0
            ;;
        validate)
            test_configuration_menu
            exit 0
            ;;
        info)
            show_connection_instructions
            exit 0
            ;;
    esac

    # Verify environment for interactive mode
    if [[ "$DRY_RUN" != true ]]; then
        if ! check_ubuntu_version; then
            print_error "Aborting. This script requires Ubuntu Linux (22.04 LTS or 24.04 LTS)."
            print_error "For offline demonstration on other systems, run with: --dry-run --skip-os-check"
            exit 1
        fi
        if [[ "$EUID" -ne 0 ]]; then
            print_warning "Non-root user detected (UID $EUID)."
            print_warning "Real setup, package installation, and /etc/samba editing require superuser privileges."
            print_warning "To perform live changes on your Ubuntu server, please run: sudo $0"
            if confirm_action "Would you like to switch to Dry-Run mode to safely explore?" "Y"; then
                DRY_RUN=true
            else
                exit 1
            fi
        fi
    fi

    # Start main interactive menu
    main_menu
}

main "$@"
