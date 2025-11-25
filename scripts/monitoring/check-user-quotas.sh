#!/bin/bash
set -euo pipefail

# Check user disk usage against quotas
# This script monitors each user's storage consumption and alerts when quotas are exceeded

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Load configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi

source "${CONFIG_FILE}"

# Configuration constants
MOUNT_POINT="${MOUNT_POINT:-/mnt/storage}"
USER_QUOTA_GB="${USER_QUOTA_GB:-100}"
WARNING_THRESHOLD_PERCENT=90
CRITICAL_THRESHOLD_PERCENT=100

# Get list of users from config
if [[ -z "${USERS:-}" ]]; then
    echo "ERROR: USERS variable not set in configuration"
    exit 1
fi

# Convert USERS string to array
read -ra user_array <<< "${USERS}"

echo "Checking disk usage for ${#user_array[@]} users..."
echo "Quota per user: ${USER_QUOTA_GB}GB"
echo ""

# Check each user's disk usage
for username in "${user_array[@]}"; do
    user_home_path="${MOUNT_POINT}/homes/${username}"

    # Skip if user directory doesn't exist
    if [[ ! -d "${user_home_path}" ]]; then
        echo "WARNING: User directory not found: ${user_home_path}"
        continue
    fi

    # Calculate usage in GB using du
    usage_gb=$(du -s --block-size=1G "${user_home_path}" 2>/dev/null | cut -f1)

    # Handle case where du returns 0 for very small directories
    if [[ -z "${usage_gb}" ]] || [[ "${usage_gb}" == "0" ]]; then
        # Try to get more precise measurement in MB and convert to GB
        usage_mb=$(du -s --block-size=1M "${user_home_path}" 2>/dev/null | cut -f1)
        usage_gb=$(awk "BEGIN {printf \"%.1f\", ${usage_mb} / 1024.0}")
    fi

    # Calculate usage percentage
    usage_percent=$(awk "BEGIN {printf \"%.1f\", (${usage_gb} * 100.0) / ${USER_QUOTA_GB}}")

    echo "User: ${username}"
    echo "  Usage: ${usage_gb}GB / ${USER_QUOTA_GB}GB (${usage_percent}%)"

    # Check if usage exceeds critical threshold
    if awk "BEGIN {exit !(${usage_gb} >= ${USER_QUOTA_GB})}"; then
        message="User ${username} exceeded quota: ${usage_gb}GB / ${USER_QUOTA_GB}GB (${usage_percent}%)"
        echo "  ❌ CRITICAL: ${message}"

        if [[ -x "${ALERT_SCRIPT}" ]]; then
            "${ALERT_SCRIPT}" "critical" "${message}"
        fi
    # Check if usage exceeds warning threshold
    elif awk "BEGIN {exit !(${usage_percent} >= ${WARNING_THRESHOLD_PERCENT})}"; then
        message="User ${username} approaching quota: ${usage_gb}GB / ${USER_QUOTA_GB}GB (${usage_percent}%)"
        echo "  ⚠️  WARNING: ${message}"

        if [[ -x "${ALERT_SCRIPT}" ]]; then
            "${ALERT_SCRIPT}" "warning" "${message}"
        fi
    else
        echo "  ✅ OK"
    fi

    echo ""
done

echo "Quota check completed at $(date)"
