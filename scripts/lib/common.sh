#!/bin/bash
# Common functions library for ML Training Server setup scripts
# Source this file in other scripts: source "${SCRIPT_DIR}/lib/common.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions with colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if a command exists
# Usage: check_command jq "Install with: apt install jq"
check_command() {
    local cmd="$1"
    local install_msg="${2:-Install $cmd first}"

    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found"
        log_info "$install_msg"
        return 1
    fi
    return 0
}

# Check multiple commands at once
# Usage: check_commands "jq curl docker"
check_commands() {
    local missing=()
    for cmd in $1; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install with: apt install ${missing[*]}"
        return 1
    fi
    return 0
}

# Send alert via Telegram (if configured)
# Usage: send_alert "info|warning|critical|success" "message"
send_alert() {
    local level="$1"
    local message="$2"
    local alert_script="/opt/scripts/monitoring/send-telegram-alert.sh"

    if [[ -x "${alert_script}" ]]; then
        "${alert_script}" "${level}" "${message}"
    else
        # Fallback: just log to console
        case "${level}" in
            critical|error)
                log_error "$message"
                ;;
            warning)
                log_warning "$message"
                ;;
            success)
                log_success "$message"
                ;;
            *)
                log_info "$message"
                ;;
        esac
    fi
}

# Check if running as root
# Usage: require_root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Load configuration file with validation
# Usage: load_config "/path/to/config.sh"
load_config() {
    local config_file="$1"

    if [[ ! -f "${config_file}" ]]; then
        log_error "Configuration file not found: ${config_file}"
        log_info "Please create config.sh from config.sh.example"
        exit 1
    fi

    # Source the config file
    # shellcheck source=/dev/null
    source "${config_file}"
    log_success "Configuration loaded from ${config_file}"
}

# Validate required environment variables
# Usage: require_vars "VAR1 VAR2 VAR3"
require_vars() {
    local missing=()
    for var in $1; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables: ${missing[*]}"
        log_info "Please set these variables in config.sh"
        exit 1
    fi
}

# Check network connectivity with retry and exponential backoff
# Usage: check_network [max_retries]
# Returns: 0 on success, 1 on failure
check_network() {
    local max_retries=${1:-3}
    local retry_count=0
    local wait_time=2

    log_info "Checking network connectivity..."

    while [[ $retry_count -lt $max_retries ]]; do
        if ping -c 1 -W 5 8.8.8.8 &>/dev/null || \
           ping -c 1 -W 5 1.1.1.1 &>/dev/null || \
           getent hosts google.com &>/dev/null; then
            log_success "Network connectivity verified"
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_info "Network check failed (attempt $retry_count/$max_retries), retrying in ${wait_time}s..."
            sleep $wait_time
            wait_time=$((wait_time * 2))  # Exponential backoff
        fi
    done

    # All retries failed
    log_error "No network connectivity after $max_retries attempts"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check physical network connection (cable/WiFi)"
    echo "  2. Verify network interface is up: ip link show"
    echo "  3. Check IP address assignment: ip addr show"
    echo "  4. Test DNS resolution: nslookup google.com"
    echo "  5. Check firewall settings: ufw status"
    echo "  6. Verify default gateway: ip route show"
    echo ""
    return 1
}

# Cleanup trap for temporary files and directories
# Usage: setup_cleanup_trap "/tmp/mydir /tmp/myfile"
setup_cleanup_trap() {
    local cleanup_items="$1"

    cleanup() {
        log_info "Cleaning up..."
        for item in $cleanup_items; do
            if [[ -e "$item" ]]; then
                rm -rf "$item"
                log_info "Removed: $item"
            fi
        done
    }

    trap cleanup EXIT ERR INT TERM
}

# Retry a command with exponential backoff
# Usage: retry 5 "docker pull myimage:latest"
retry() {
    local max_attempts="$1"
    shift
    local cmd="$@"
    local attempt=1
    local delay=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: $cmd"

        if eval "$cmd"; then
            log_success "Command succeeded on attempt $attempt"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Command failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts"
    return 1
}

# Iterate over users from config
# Usage: for_each_user callback_function
for_each_user() {
    local callback="$1"
    local user_index=0

    # Convert USERS string to array
    read -ra user_array <<< "${USERS}"

    for username in "${user_array[@]}"; do
        local uid=$((FIRST_UID + user_index))

        # Call the callback function with username, uid, and index
        "$callback" "$username" "$uid" "$user_index"

        user_index=$((user_index + 1))
    done
}

# Validate disk space availability
# Usage: check_disk_space "/mnt/storage" 100  # Check for 100GB free
check_disk_space() {
    local path="$1"
    local required_gb="$2"

    local available_gb=$(df -BG "$path" | tail -1 | awk '{print $4}' | sed 's/G//')

    if [[ $available_gb -lt $required_gb ]]; then
        log_error "Insufficient disk space on $path"
        log_error "  Required: ${required_gb}GB"
        log_error "  Available: ${available_gb}GB"
        return 1
    fi

    log_success "Disk space check passed: ${available_gb}GB available (required: ${required_gb}GB)"
    return 0
}

# Calculate retention storage needs
# Usage: calculate_retention_storage 7 52  # 7 daily, 52 weekly
calculate_retention_storage() {
    local daily_count="$1"
    local weekly_count="$2"
    local base_size="$3"  # Base backup size in GB

    # Estimate with 20% deduplication savings
    local total_snapshots=$((daily_count + weekly_count))
    local estimated_gb=$(awk "BEGIN {printf \"%.0f\", ${base_size} * ${total_snapshots} * 0.8}")

    echo "$estimated_gb"
}

# Progress bar for long operations
# Usage: show_progress 30 100  # 30 out of 100
show_progress() {
    local current="$1"
    local total="$2"
    local width=50

    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\rProgress: ["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] %d%%" "$percent"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# Export all functions so they're available in subshells
export -f log_info log_success log_warning log_error
export -f check_command check_commands send_alert
export -f require_root load_config require_vars
export -f check_network setup_cleanup_trap retry
export -f for_each_user check_disk_space calculate_retention_storage
export -f show_progress
