#!/bin/bash
set -euo pipefail

# ML Training Server - Configuration Validation Script
# Run this before any setup scripts to validate your configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo ""
    echo "Please create it first:"
    echo "  cp config.sh.example config.sh"
    echo "  nano config.sh"
    exit 1
fi

source "${CONFIG_FILE}"

echo "=== ML Training Server - Configuration Validation ==="
echo ""

ERRORS=0
WARNINGS=0

# Validate required settings
echo "Checking required settings..."

if [[ -z "${USERS}" ]]; then
    echo "  ✗ ERROR: USERS is not set"
    ((ERRORS++))
else
    USER_COUNT=$(get_user_count)
    echo "  ✓ Users configured: ${USERS} (${USER_COUNT} users)"
fi

if [[ -z "${MOUNT_POINT}" ]]; then
    echo "  ✗ ERROR: MOUNT_POINT is not set"
    ((ERRORS++))
else
    echo "  ✓ Mount point: ${MOUNT_POINT}"
fi

# Validate MOUNT_POINT format
if [[ "${MOUNT_POINT}" =~ [[:space:]] ]]; then
    echo "  ✗ ERROR: MOUNT_POINT cannot contain spaces: '${MOUNT_POINT}'"
    ((ERRORS++))
elif [[ ! "${MOUNT_POINT}" =~ ^/ ]]; then
    echo "  ✗ ERROR: MOUNT_POINT must be an absolute path: '${MOUNT_POINT}'"
    ((ERRORS++))
else
    echo "  ✓ Mount point format is valid: ${MOUNT_POINT}"
fi

if [[ -z "${DOMAIN}" ]]; then
    echo "  ✗ ERROR: DOMAIN is not set (required for Cloudflare Tunnel)"
    ((ERRORS++))
else
    echo "  ✓ Domain: ${DOMAIN}"
fi

# Check storage configuration
echo ""
echo "Checking storage configuration..."

NVME=$(detect_nvme_device)
if [[ -z "${NVME}" ]]; then
    echo "  ⚠ WARNING: No SSD/NVMe device detected"
    ((WARNINGS++))
else
    echo "  ✓ SSD/NVMe: ${NVME}"
    if [[ -b "${NVME}" ]]; then
        # Try to get size, but make it non-fatal if not running as root
        if [[ $EUID -eq 0 ]]; then
            SIZE=$(blockdev --getsize64 ${NVME} 2>/dev/null | awk '{print int($1/1024/1024/1024)"GB"}' || echo "unknown")
        else
            SIZE=$(lsblk -ndo SIZE ${NVME} 2>/dev/null || echo "unknown")
        fi
        echo "    Size: ${SIZE}"
    fi
fi

HDDS=$(detect_hdd_devices)
HDD_ARRAY=(${HDDS})
HDD_COUNT=${#HDD_ARRAY[@]}

if [[ ${HDD_COUNT} -eq 0 ]]; then
    echo "  ✗ ERROR: No HDDs detected"
    ((ERRORS++))
else
    echo "  ✓ HDDs detected: ${HDD_COUNT}"
    for hdd in ${HDDS}; do
        if [[ -b "${hdd}" ]]; then
            SIZE=$(blockdev --getsize64 ${hdd} 2>/dev/null | awk '{print int($1/1024/1024/1024)"GB"}' || echo "unknown")
            echo "    - ${hdd}: ${SIZE}"
        fi
    done
fi

# Validate RAID level
echo ""
echo "Checking RAID configuration..."

case "${BTRFS_RAID_LEVEL}" in
    raid10)
        if [[ ${HDD_COUNT} -lt 4 ]]; then
            echo "  ✗ ERROR: RAID10 requires at least 4 disks, found ${HDD_COUNT}"
            ((ERRORS++))
        else
            echo "  ✓ RAID10 with ${HDD_COUNT} disks"
        fi
        ;;
    raid1)
        if [[ ${HDD_COUNT} -lt 2 ]]; then
            echo "  ✗ ERROR: RAID1 requires at least 2 disks, found ${HDD_COUNT}"
            ((ERRORS++))
        else
            echo "  ✓ RAID1 with ${HDD_COUNT} disks"
        fi
        ;;
    raid0)
        if [[ ${HDD_COUNT} -lt 2 ]]; then
            echo "  ⚠ WARNING: RAID0 requires at least 2 disks, found ${HDD_COUNT}"
            ((WARNINGS++))
        else
            echo "  ⚠ RAID0 with ${HDD_COUNT} disks (NO REDUNDANCY!)"
            ((WARNINGS++))
        fi
        ;;
    single)
        echo "  ⚠ WARNING: Single disk mode (NO REDUNDANCY!)"
        ((WARNINGS++))
        ;;
    *)
        echo "  ✗ ERROR: Unknown RAID level: ${BTRFS_RAID_LEVEL}"
        ((ERRORS++))
        ;;
esac

# Check numeric values
echo ""
echo "Checking numeric values..."

for var in FIRST_UID OS_PARTITION_SIZE_GB MEMORY_GUARANTEE_GB MEMORY_LIMIT_GB SWAP_SIZE_GB USER_QUOTA_GB; do
    val="${!var}"
    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
        echo "  ✗ ERROR: ${var} must be a number, got '${val}'"
        ((ERRORS++))
    else
        echo "  ✓ ${var}: ${val}"
    fi
done

# Logic validation
echo ""
echo "Checking logic constraints..."

if [[ ${MEMORY_GUARANTEE_GB} -gt ${MEMORY_LIMIT_GB} ]]; then
    echo "  ✗ ERROR: MEMORY_GUARANTEE_GB (${MEMORY_GUARANTEE_GB}) > MEMORY_LIMIT_GB (${MEMORY_LIMIT_GB})"
    ((ERRORS++))
else
    echo "  ✓ Memory limits are logical"
fi

# Check if total user quota exceeds expected storage
TOTAL_USER_QUOTA_GB=$((USER_QUOTA_GB * $(get_user_count)))

# Check if user data + snapshots (50% overhead) exceeds safe limit (80% of disk)
# Account for BTRFS metadata overhead (5%)
BTRFS_OVERHEAD=0.95
TOTAL_WITH_SNAPSHOTS=$(awk "BEGIN {printf \"%.0f\", ${TOTAL_USER_QUOTA_GB} * 1.5}")  # User data + 50% snapshots
SAFE_LIMIT_GB=$(awk "BEGIN {printf \"%.0f\", ${ESTIMATED_CAPACITY_GB} * ${BTRFS_OVERHEAD} * 0.8}")  # 80% of capacity after BTRFS overhead

if [[ ${TOTAL_WITH_SNAPSHOTS} -gt ${SAFE_LIMIT_GB} ]]; then
    echo "  ⚠ WARNING: Total user quota + snapshots (${TOTAL_USER_QUOTA_GB}GB + 50%) may exceed safe storage limit"
    echo "    User data: ${TOTAL_USER_QUOTA_GB}GB, With snapshots: ~$(awk "BEGIN {printf \"%.1f\", ${TOTAL_USER_QUOTA_GB} * 1.5}")GB"
    echo "    Safe limit: $(awk "BEGIN {printf \"%.0f\", ${SAFE_LIMIT_GB} / 1024}")TB (80% of estimated ${ESTIMATED_CAPACITY_GB}GB)"
    ((WARNINGS++))
else
    echo "  ✓ Total user quota: ${TOTAL_USER_QUOTA_GB}GB - reasonable for ${ESTIMATED_CAPACITY_GB}GB storage"
fi

# Check UID range
MAX_UID=$((FIRST_UID + $(get_user_count) - 1))
if [[ ${MAX_UID} -gt 60000 ]]; then
    echo "  ✗ ERROR: UID range will exceed 60000 (FIRST_UID: ${FIRST_UID}, users: $(get_user_count), max UID: ${MAX_UID})"
    echo "    Reduce FIRST_UID or number of users"
    ((ERRORS++))
else
    echo "  ✓ UID range: ${FIRST_UID}-${MAX_UID}"
fi

# Check port ranges
MAX_USERS=$(get_user_count)
SSH_BASE_PORT=${SSH_BASE_PORT:-2222}  # Default: 2222
VNC_BASE_PORT=${VNC_BASE_PORT:-5900}  # Default: 5900
RDP_BASE_PORT=${RDP_BASE_PORT:-3389}  # Default: 3389
NOVNC_BASE_PORT=${NOVNC_BASE_PORT:-6080}  # Default: 6080
MAX_SSH_PORT=$((SSH_BASE_PORT + MAX_USERS))
MAX_VNC_PORT=$((VNC_BASE_PORT + MAX_USERS))
MAX_RDP_PORT=$((RDP_BASE_PORT + MAX_USERS))
MAX_NOVNC_PORT=$((NOVNC_BASE_PORT + MAX_USERS))

echo "  ✓ Port ranges: SSH ${SSH_BASE_PORT}-${MAX_SSH_PORT}, VNC ${VNC_BASE_PORT}-${MAX_VNC_PORT}, RDP ${RDP_BASE_PORT}-${MAX_RDP_PORT}, noVNC ${NOVNC_BASE_PORT}-${MAX_NOVNC_PORT}"

if [[ ${MAX_USERS} -gt 50 ]]; then
    echo "  ⚠ WARNING: ${MAX_USERS} users may strain resources"
    ((WARNINGS++))
fi

# Check for default passwords
echo ""
echo "Checking password security..."

if [[ "${GRAFANA_ADMIN_PASSWORD:-admin}" == "admin" ]]; then
    echo "  ⚠ WARNING: Grafana using default password 'admin'"
    echo "    Set GRAFANA_ADMIN_PASSWORD in config.sh or .env"
    ((WARNINGS++))
fi

# Check domain if Cloudflare is being used
echo ""
echo "Checking network configuration..."

if [[ -z "${DOMAIN}" ]]; then
    echo "  ⚠ WARNING: DOMAIN is not set (required for Cloudflare Tunnel)"
    ((WARNINGS++))
else
    echo "  ✓ Domain: ${DOMAIN}"
fi

# Check GPU
if ! nvidia-smi &>/dev/null; then
    echo "  ⚠ WARNING: No NVIDIA GPU detected"
    ((WARNINGS++))
else
    echo "  ✓ NVIDIA GPU detected"
fi

# Check rclone remotes if configured
if [[ -n "${BACKUP_REMOTE}" ]]; then
    REMOTE_NAME=$(echo "${BACKUP_REMOTE}" | cut -d: -f1)
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
        echo "  ⚠ WARNING: Backup remote '${REMOTE_NAME}' not configured in rclone"
        echo "    Run 'rclone config' to set up ${REMOTE_NAME} before running setup"
        ((WARNINGS++))
    fi
fi

# Summary
echo ""
echo "=== Validation Summary ==="
echo "Errors: ${ERRORS}"
echo "Warnings: ${WARNINGS}"
echo ""

if [[ ${ERRORS} -gt 0 ]]; then
    echo "❌ Configuration has errors. Please fix them before proceeding."
    exit 1
elif [[ ${WARNINGS} -gt 0 ]]; then
    echo "⚠️  Configuration has warnings. Review them before proceeding."
    exit 0
else
    echo "✅ Configuration is valid!"
    exit 0
fi
