#!/bin/bash
set -euo pipefail

# BTRFS RAID health monitoring script
# Checks device statistics and RAID status for data integrity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/mnt/storage}"

# Verify mount point exists
if [[ ! -d "${MOUNT_POINT}" ]]; then
    message="ERROR: BTRFS mount point does not exist: ${MOUNT_POINT}"
    echo "${message}"
    [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "critical" "${message}"
    exit 1
fi

# Verify BTRFS is mounted
if ! mountpoint -q "${MOUNT_POINT}"; then
    message="CRITICAL: ${MOUNT_POINT} is not mounted!"
    echo "${message}"
    [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "critical" "${message}"
    exit 1
fi

echo "=== BTRFS RAID Health Check ==="
echo "Mount point: ${MOUNT_POINT}"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check device statistics for errors
echo "Checking device statistics..."
device_stats_output=$(btrfs device stats "${MOUNT_POINT}" 2>&1 || echo "")

if [[ -z "${device_stats_output}" ]]; then
    message="WARNING: Could not retrieve BTRFS device statistics"
    echo "${message}"
    [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "warning" "${message}"
else
    echo "${device_stats_output}"
    echo ""

    # Parse device stats and check for errors
    has_errors=0
    while IFS= read -r line; do
        # Extract device path and error counts
        if [[ "${line}" =~ \[([^\]]+)\] ]]; then
            device_path="${BASH_REMATCH[1]}"

            # Check if this line contains error counts
            if echo "${line}" | grep -q "write_io_errs\|read_io_errs\|flush_io_errs\|corruption_errs\|generation_errs"; then
                # Extract error count (number after the error type)
                error_count=$(echo "${line}" | awk '{print $NF}')

                # Alert if any errors are found
                if [[ "${error_count}" -gt 0 ]]; then
                    has_errors=1
                    error_type=$(echo "${line}" | awk '{print $2}')
                    message="CRITICAL: BTRFS device ${device_path} has ${error_count} ${error_type}"
                    echo "❌ ${message}"
                    [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "critical" "${message}"
                fi
            fi
        fi
    done <<< "${device_stats_output}"

    if [[ ${has_errors} -eq 0 ]]; then
        echo "✅ No device errors detected"
    fi
fi

echo ""

# Check RAID level and degraded status
echo "Checking RAID configuration..."
filesystem_df=$(btrfs filesystem df "${MOUNT_POINT}" 2>&1 || echo "")

if [[ -z "${filesystem_df}" ]]; then
    message="WARNING: Could not retrieve BTRFS filesystem information"
    echo "${message}"
    [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "warning" "${message}"
else
    echo "${filesystem_df}"
    echo ""

    # Check for single/degraded mode
    if echo "${filesystem_df}" | grep -iq "single"; then
        message="CRITICAL: BTRFS filesystem is in SINGLE mode (RAID degraded or failed)!"
        echo "❌ ${message}"
        [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "critical" "${message}"
    elif echo "${filesystem_df}" | grep -iq "raid"; then
        raid_level=$(echo "${filesystem_df}" | grep -i "raid" | head -1 | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
        echo "✅ RAID status: ${raid_level}"
    else
        message="WARNING: Could not determine RAID status"
        echo "⚠️  ${message}"
    fi
fi

echo ""

# Check filesystem usage
echo "Checking filesystem usage..."
usage_percent=$(df --output=pcent "${MOUNT_POINT}" | tail -1 | tr -d ' %')

if [[ -n "${usage_percent}" ]]; then
    echo "Filesystem usage: ${usage_percent}%"

    if (( usage_percent > 95 )); then
        message="CRITICAL: BTRFS filesystem is ${usage_percent}% full (critically high)"
        echo "❌ ${message}"
        [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "critical" "${message}"
    elif (( usage_percent > 90 )); then
        message="WARNING: BTRFS filesystem is ${usage_percent}% full"
        echo "⚠️  ${message}"
        [[ -x "${ALERT_SCRIPT}" ]] && "${ALERT_SCRIPT}" "warning" "${message}"
    else
        echo "✅ Filesystem usage healthy"
    fi
else
    message="WARNING: Could not determine filesystem usage"
    echo "⚠️  ${message}"
fi

echo ""

# Show device information
echo "Device information:"
btrfs filesystem show "${MOUNT_POINT}" 2>&1 || echo "Could not retrieve device information"

echo ""
echo "=== BTRFS RAID health check completed ==="
