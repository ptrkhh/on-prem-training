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
    if type -t get_user_count &>/dev/null; then
        USER_COUNT=$(get_user_count)
    else
        # Fallback if function not defined
        USER_COUNT=$(echo ${USERS} | wc -w)
    fi
    echo "  ✓ Users configured: ${USERS} (${USER_COUNT} users)"

    # Validate each username format (lowercase, start with letter, alphanumeric + hyphens)
    USER_ARRAY=(${USERS})
    for username in "${USER_ARRAY[@]}"; do
        if [[ ! "${username}" =~ ^[a-z][-a-z0-9]*$ ]]; then
            echo "  ✗ ERROR: Invalid username '${username}'"
            echo "    Usernames must start with a lowercase letter and contain only lowercase letters, digits, and hyphens"
            ((ERRORS++))
        elif [[ ${#username} -gt 32 ]]; then
            echo "  ✗ ERROR: Username '${username}' is too long (max 32 characters)"
            ((ERRORS++))
        elif [[ ${#username} -lt 1 ]]; then
            echo "  ✗ ERROR: Username cannot be empty"
            ((ERRORS++))
        fi
    done
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

if type -t detect_nvme_device &>/dev/null; then
    NVME=$(detect_nvme_device)
else
    # Fallback if function not defined
    NVME="${NVME_DEVICE:-}"
    if [[ -z "${NVME}" ]]; then
        [[ -b "/dev/nvme0n1" ]] && NVME="/dev/nvme0n1"
        [[ -b "/dev/sda" ]] && NVME="/dev/sda"
    fi
fi

if [[ -z "${NVME}" ]]; then
    echo "  ⚠ WARNING: No SSD/NVMe device detected"
    ((WARNINGS++))
else
    echo "  ✓ SSD/NVMe: ${NVME}"
    if [[ -b "${NVME}" ]]; then
        SIZE=$(lsblk -ndo SIZE ${NVME} 2>/dev/null || echo "unknown")
        echo "    Size: ${SIZE}"
    fi
fi

if type -t detect_hdd_devices &>/dev/null; then
    HDDS=$(detect_hdd_devices)
else
    # Fallback if function not defined
    HDDS="${HDD_DEVICES:-}"
    if [[ -z "${HDDS}" ]]; then
        hdds=""
        for dev in /dev/sd{b..z}; do
            if [[ -b "${dev}" ]] && [[ "${dev}" != "${NVME}" ]]; then
                disk_name=$(basename ${dev})
                if [[ -f "/sys/block/${disk_name}/queue/rotational" ]]; then
                    [[ "$(cat /sys/block/${disk_name}/queue/rotational)" == "1" ]] && hdds="${hdds} ${dev}"
                fi
            fi
        done
        HDDS=${hdds}
    fi
fi
HDD_ARRAY=(${HDDS})
HDD_COUNT=${#HDD_ARRAY[@]}

# Check for single NVMe mode (no HDDs)
SINGLE_NVME_MODE=false
if [[ -n "${NVME}" && ${HDD_COUNT} -eq 0 ]]; then
    SINGLE_NVME_MODE=true
    echo "  ℹ Single NVMe mode detected (no HDDs)"
fi

if [[ ${HDD_COUNT} -eq 0 ]]; then
    if [[ "${SINGLE_NVME_MODE}" == "false" ]]; then
        echo "  ✗ ERROR: No HDDs detected and no NVMe available for single NVMe mode"
        ((ERRORS++))
    else
        echo "  ✓ Single NVMe mode: Will use NVMe partition for storage"
    fi
else
    echo "  ✓ HDDs detected: ${HDD_COUNT}"
    for hdd in ${HDDS}; do
        if [[ -b "${hdd}" ]]; then
            SIZE=$(lsblk -ndo SIZE ${hdd} 2>/dev/null || echo "unknown")
            echo "    - ${hdd}: ${SIZE}"
        fi
    done
fi

# Validate RAID level
echo ""
echo "Checking RAID configuration..."

DEVICE_COUNT=${HDD_COUNT}
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    DEVICE_COUNT=1
fi

case "${BTRFS_RAID_LEVEL}" in
    raid10)
        if [[ ${DEVICE_COUNT} -lt 4 ]]; then
            echo "  ✗ ERROR: RAID10 requires at least 4 disks, found ${DEVICE_COUNT}"
            ((ERRORS++))
        else
            echo "  ✓ RAID10 with ${DEVICE_COUNT} disks"
        fi
        ;;
    raid1)
        if [[ ${DEVICE_COUNT} -lt 2 ]]; then
            echo "  ✗ ERROR: RAID1 requires at least 2 disks, found ${DEVICE_COUNT}"
            ((ERRORS++))
        else
            echo "  ✓ RAID1 with ${DEVICE_COUNT} disks"
        fi
        ;;
    raid0)
        if [[ ${DEVICE_COUNT} -lt 2 ]]; then
            echo "  ⚠ WARNING: RAID0 requires at least 2 disks, found ${DEVICE_COUNT}"
            ((WARNINGS++))
        else
            echo "  ⚠ RAID0 with ${DEVICE_COUNT} disks (NO REDUNDANCY!)"
            ((WARNINGS++))
        fi
        ;;
    single)
        if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
            echo "  ✓ Single NVMe mode (NO REDUNDANCY!)"
        else
            echo "  ⚠ WARNING: Single disk mode (NO REDUNDANCY!)"
            ((WARNINGS++))
        fi
        ;;
    *)
        echo "  ✗ ERROR: Unknown RAID level: ${BTRFS_RAID_LEVEL}"
        ((ERRORS++))
        ;;
esac

# Validate bcache mode for single NVMe
if [[ "${SINGLE_NVME_MODE}" == "true" && "${BCACHE_MODE}" != "none" ]]; then
    echo "  ✗ ERROR: bcache mode must be 'none' for single NVMe setups"
    echo "    Current setting: ${BCACHE_MODE}"
    echo "    Set BCACHE_MODE=\"none\" in config.sh to avoid partition conflicts"
    ((ERRORS++))
fi

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
if type -t get_user_count &>/dev/null; then
    TOTAL_USER_QUOTA_GB=$((USER_QUOTA_GB * $(get_user_count)))
else
    TOTAL_USER_QUOTA_GB=$((USER_QUOTA_GB * $(echo ${USERS} | wc -w)))
fi

# Check if user data + snapshots (50% overhead) exceeds safe limit (80% of disk)
# Account for BTRFS metadata overhead (5%)
BTRFS_OVERHEAD=0.95
TOTAL_WITH_SNAPSHOTS=$(awk "BEGIN {printf \"%.0f\", ${TOTAL_USER_QUOTA_GB} * 1.5}")  # User data + 50% snapshots
SAFE_LIMIT_GB=$(awk "BEGIN {printf \"%.0f\", ${ESTIMATED_CAPACITY_GB} * ${BTRFS_OVERHEAD} * 0.8}")  # 80% of capacity after BTRFS overhead

if [[ ${TOTAL_WITH_SNAPSHOTS} -gt ${SAFE_LIMIT_GB} ]]; then
    echo "  ⚠ WARNING: Total user quota + snapshots (${TOTAL_USER_QUOTA_GB}GB + 50%) may exceed safe storage limit"
    echo "    User data: ${TOTAL_USER_QUOTA_GB}GB, With snapshots: ~$(awk "BEGIN {printf \"%.1f\", ${TOTAL_USER_QUOTA_GB} * 1.5}")GB"
    echo "    Safe limit: $(awk "BEGIN {printf \"%.0f\", ${SAFE_LIMIT_GB}}")GB (80% of estimated ${ESTIMATED_CAPACITY_GB}GB)"
    ((WARNINGS++))
else
    echo "  ✓ Total user quota: ${TOTAL_USER_QUOTA_GB}GB - reasonable for ${ESTIMATED_CAPACITY_GB}GB storage"
fi

# Check UID range
if type -t get_user_count &>/dev/null; then
    MAX_UID=$((FIRST_UID + $(get_user_count) - 1))
    USER_CT=$(get_user_count)
else
    USER_CT=$(echo ${USERS} | wc -w)
    MAX_UID=$((FIRST_UID + ${USER_CT} - 1))
fi
if [[ ${MAX_UID} -gt 60000 ]]; then
    echo "  ✗ ERROR: UID range will exceed 60000 (FIRST_UID: ${FIRST_UID}, users: ${USER_CT}, max UID: ${MAX_UID})"
    echo "    Reduce FIRST_UID or number of users"
    ((ERRORS++))
else
    echo "  ✓ UID range: ${FIRST_UID}-${MAX_UID}"
fi

# Check port ranges
if type -t get_user_count &>/dev/null; then
    MAX_USERS=$(get_user_count)
else
    MAX_USERS=$(echo ${USERS} | wc -w)
fi
SSH_BASE_PORT=${SSH_BASE_PORT:-2222}  # Default: 2222
VNC_BASE_PORT=${VNC_BASE_PORT:-5900}  # Default: 5900
RDP_BASE_PORT=${RDP_BASE_PORT:-3389}  # Default: 3389
NOVNC_BASE_PORT=${NOVNC_BASE_PORT:-6080}  # Default: 6080
MAX_SSH_PORT=$((SSH_BASE_PORT + MAX_USERS))
MAX_VNC_PORT=$((VNC_BASE_PORT + MAX_USERS))
MAX_RDP_PORT=$((RDP_BASE_PORT + MAX_USERS))
MAX_NOVNC_PORT=$((NOVNC_BASE_PORT + MAX_USERS))

# Validate port ranges don't exceed 65535
for port_range in "SSH:${SSH_BASE_PORT}:${MAX_SSH_PORT}" \
                   "VNC:${VNC_BASE_PORT}:${MAX_VNC_PORT}" \
                   "RDP:${RDP_BASE_PORT}:${MAX_RDP_PORT}" \
                   "noVNC:${NOVNC_BASE_PORT}:${MAX_NOVNC_PORT}"; do
    NAME=$(echo ${port_range} | cut -d: -f1)
    BASE=$(echo ${port_range} | cut -d: -f2)
    MAX=$(echo ${port_range} | cut -d: -f3)

    if [[ ${MAX} -gt 65535 ]]; then
        echo "  ✗ ERROR: ${NAME} port range exceeds maximum (${MAX} > 65535)"
        echo "    Reduce number of users or change base port"
        ((ERRORS++))
    fi
done

echo "  ✓ Port ranges: SSH ${SSH_BASE_PORT}-${MAX_SSH_PORT}, VNC ${VNC_BASE_PORT}-${MAX_VNC_PORT}, RDP ${RDP_BASE_PORT}-${MAX_RDP_PORT}, noVNC ${NOVNC_BASE_PORT}-${MAX_NOVNC_PORT}"

# Check for port conflicts
echo ""
echo "Checking for port conflicts..."
PORTS_TO_CHECK="${SSH_BASE_PORT} ${VNC_BASE_PORT} ${RDP_BASE_PORT} ${NOVNC_BASE_PORT}"
PORTS_TO_CHECK="${PORTS_TO_CHECK} ${TRAEFIK_PORT:-80} ${GRAFANA_PORT:-3000} ${PROMETHEUS_PORT:-9090}"

PORT_CONFLICTS=false
if command -v ss &>/dev/null; then
    for PORT in ${PORTS_TO_CHECK}; do
        if ss -tuln | grep -q ":${PORT} "; then
            LISTENING_PROCESS=$(ss -tulnp | grep ":${PORT} " | head -n1 | awk '{print $7}' | cut -d'"' -f2 || echo "unknown")
            echo "  ⚠ WARNING: Port ${PORT} is already in use by ${LISTENING_PROCESS}"
            PORT_CONFLICTS=true
            ((WARNINGS++))
        fi
    done
    if [[ "${PORT_CONFLICTS}" == "false" ]]; then
        echo "  ✓ No port conflicts detected"
    fi
else
    echo "  ⚠ WARNING: 'ss' command not available, cannot check for port conflicts"
    echo "    Install iproute2 package to enable port conflict detection"
    ((WARNINGS++))
fi

if [[ ${MAX_USERS} -gt 50 ]]; then
    echo "  ⚠ WARNING: ${MAX_USERS} users may strain resources"
    ((WARNINGS++))
fi

# Check for default passwords
echo ""
echo "Checking password security..."

# Check GRAFANA_ADMIN_PASSWORD
if [[ -z "${GRAFANA_ADMIN_PASSWORD}" ]]; then
    echo "  ✗ ERROR: GRAFANA_ADMIN_PASSWORD is not set"
    echo "    Set GRAFANA_ADMIN_PASSWORD in config.sh"
    ((ERRORS++))
elif [[ "${GRAFANA_ADMIN_PASSWORD}" == *"changeme"* ]] || [[ "${GRAFANA_ADMIN_PASSWORD}" == "admin" ]]; then
    echo "  ✗ ERROR: GRAFANA_ADMIN_PASSWORD contains default/weak value"
    echo "    Current value contains: 'changeme' or 'admin'"
    echo "    Use a strong, unique password in config.sh"
    ((ERRORS++))
else
    echo "  ✓ GRAFANA_ADMIN_PASSWORD is set"
fi

# Check USER_DEFAULT_PASSWORD
if [[ -z "${USER_DEFAULT_PASSWORD}" ]]; then
    echo "  ✗ ERROR: USER_DEFAULT_PASSWORD is not set"
    echo "    Set USER_DEFAULT_PASSWORD in config.sh"
    ((ERRORS++))
elif [[ "${USER_DEFAULT_PASSWORD}" == *"changeme"* ]] || [[ "${USER_DEFAULT_PASSWORD}" == "password" ]]; then
    echo "  ✗ ERROR: USER_DEFAULT_PASSWORD contains default/weak value"
    echo "    Current value contains: 'changeme' or 'password'"
    echo "    Use a strong password in config.sh"
    ((ERRORS++))
else
    echo "  ✓ USER_DEFAULT_PASSWORD is set"
fi

# Check GUACAMOLE_DB_PASSWORD
if [[ -z "${GUACAMOLE_DB_PASSWORD}" ]]; then
    echo "  ✗ ERROR: GUACAMOLE_DB_PASSWORD is not set"
    echo "    Set GUACAMOLE_DB_PASSWORD in config.sh"
    ((ERRORS++))
elif [[ "${GUACAMOLE_DB_PASSWORD}" == *"changeme"* ]] || [[ "${GUACAMOLE_DB_PASSWORD}" == "password" ]]; then
    echo "  ✗ ERROR: GUACAMOLE_DB_PASSWORD contains default/weak value"
    echo "    Current value contains: 'changeme' or 'password'"
    echo "    Use a strong password in config.sh"
    ((ERRORS++))
else
    echo "  ✓ GUACAMOLE_DB_PASSWORD is set"
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

# Check GPU and CUDA version
if ! nvidia-smi &>/dev/null; then
    echo "  ⚠ WARNING: No NVIDIA GPU detected"
    ((WARNINGS++))
    # If no GPU, manual CUDA_VERSION is required
    if [[ -z "${CUDA_VERSION}" ]]; then
        echo "  ✗ ERROR: CUDA_VERSION must be manually specified in config.sh when nvidia-smi is not available"
        echo "    Example: CUDA_VERSION=\"12.4.1\""
        ((ERRORS++))
    fi
else
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
    echo "  ✓ NVIDIA GPU detected: ${GPU_NAME} (${GPU_MEM}MB VRAM)"

    # Check if CUDA version can be detected
    DETECTED_CUDA=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader | head -n1 2>/dev/null)
    if [[ -z "${DETECTED_CUDA}" ]] && [[ -z "${CUDA_VERSION}" ]]; then
        echo "  ✗ ERROR: Cannot auto-detect CUDA version and CUDA_VERSION is not set in config.sh"
        echo "    Set CUDA_VERSION in config.sh (e.g., CUDA_VERSION=\"12.4.1\")"
        ((ERRORS++))
    elif [[ -n "${CUDA_VERSION}" ]]; then
        echo "  ✓ CUDA version (manual): ${CUDA_VERSION}"
    elif [[ -n "${DETECTED_CUDA}" ]]; then
        echo "  ✓ CUDA version (auto-detected): ${DETECTED_CUDA}"
    fi
fi

# System Prerequisites Check
echo ""
echo "Checking system prerequisites..."

# Check Docker
if ! command -v docker &>/dev/null; then
    echo "  ✗ ERROR: Docker not installed"
    echo "    Install Docker: https://docs.docker.com/engine/install/ubuntu/"
    ((ERRORS++))
else
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
    echo "  ✓ Docker installed: ${DOCKER_VERSION}"

    # Check Docker Compose
    if docker compose version &>/dev/null; then
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
        echo "  ✓ Docker Compose v2: ${COMPOSE_VERSION}"
    else
        echo "  ✗ ERROR: Docker Compose v2 not available"
        echo "    Upgrade Docker to get Compose v2"
        ((ERRORS++))
    fi

    # Check Docker daemon is running
    if ! docker ps &>/dev/null; then
        echo "  ✗ ERROR: Docker daemon not running"
        echo "    Start Docker: sudo systemctl start docker"
        ((ERRORS++))
    else
        echo "  ✓ Docker daemon is running"
    fi
fi

# Check required system commands
REQUIRED_COMMANDS="btrfs jq curl wget git bash awk sed grep"
MISSING_COMMANDS=()

for cmd in $REQUIRED_COMMANDS; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
    echo "  ✗ ERROR: Missing required commands: ${MISSING_COMMANDS[*]}"
    echo "    Install with: apt install btrfs-progs jq curl wget git"
    ((ERRORS++))
else
    echo "  ✓ All required commands available"
fi

# Check system memory
TOTAL_MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
MIN_MEM_GB=32

if [[ ${TOTAL_MEM_GB} -lt ${MIN_MEM_GB} ]]; then
    echo "  ⚠ WARNING: Low system memory: ${TOTAL_MEM_GB}GB (recommended: ${MIN_MEM_GB}GB+)"
    echo "    System may struggle with multiple user containers"
    ((WARNINGS++))
else
    echo "  ✓ System memory: ${TOTAL_MEM_GB}GB"
fi

# Check disk I/O scheduler (for SSD/NVMe performance)
if [[ -n "${NVME_DEVICE}" ]] && [[ -b "${NVME_DEVICE}" ]]; then
    DEVICE_NAME=$(basename "${NVME_DEVICE}")
    if [[ -f "/sys/block/${DEVICE_NAME}/queue/scheduler" ]]; then
        SCHEDULER=$(cat "/sys/block/${DEVICE_NAME}/queue/scheduler" | grep -o '\[.*\]' | tr -d '[]')
        if [[ "${SCHEDULER}" == "none" ]] || [[ "${SCHEDULER}" == "noop" ]] || [[ "${SCHEDULER}" == "mq-deadline" ]]; then
            echo "  ✓ Disk scheduler for ${NVME_DEVICE}: ${SCHEDULER} (good for SSD/NVMe)"
        else
            echo "  ⚠ WARNING: Disk scheduler for ${NVME_DEVICE}: ${SCHEDULER}"
            echo "    Recommended for SSD/NVMe: none, noop, or mq-deadline"
            echo "    Change with: echo noop | sudo tee /sys/block/${DEVICE_NAME}/queue/scheduler"
            ((WARNINGS++))
        fi
    fi
fi

# Check network bandwidth (if possible)
if command -v ethtool &>/dev/null; then
    # Get primary network interface
    PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -n "${PRIMARY_IF}" ]]; then
        LINK_SPEED=$(ethtool "${PRIMARY_IF}" 2>/dev/null | grep "Speed:" | awk '{print $2}')
        if [[ -n "${LINK_SPEED}" ]]; then
            echo "  ✓ Network interface ${PRIMARY_IF}: ${LINK_SPEED}"

            # Warn if less than 1Gbps
            if [[ "${LINK_SPEED}" != *"10000"* ]] && [[ "${LINK_SPEED}" != *"1000"* ]]; then
                echo "    ⚠ WARNING: Network speed may be slow for multi-user ML training"
                ((WARNINGS++))
            fi
        fi
    fi
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
