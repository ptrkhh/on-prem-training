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
        SIZE=$(blockdev --getsize64 ${NVME} 2>/dev/null | awk '{print int($1/1024/1024/1024)"GB"}' || echo "unknown")
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

for var in FIRST_UID OS_PARTITION_SIZE_GB MEMORY_GUARANTEE_GB MEMORY_LIMIT_GB SWAP_SIZE_GB; do
    val="${!var}"
    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
        echo "  ✗ ERROR: ${var} must be a number, got '${val}'"
        ((ERRORS++))
    else
        echo "  ✓ ${var}: ${val}"
    fi
done

# Check domain if Cloudflare is being used
echo ""
echo "Checking network configuration..."

if [[ -z "${DOMAIN}" ]]; then
    echo "  ⚠ WARNING: DOMAIN is not set (required for Cloudflare Tunnel)"
    ((WARNINGS++))
else
    echo "  ✓ Domain: ${DOMAIN}"
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
