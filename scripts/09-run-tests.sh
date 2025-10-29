#!/bin/bash
set -euo pipefail

# ML Training Server - System Tests
# Comprehensive validation of all components

echo "========================================="
echo "  ML Training Server - System Tests"
echo "========================================="
echo ""

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example"
    exit 1
fi

source "${CONFIG_FILE}"

# Convert users string to array
USER_ARRAY=(${USERS})
USER_COUNT=${#USER_ARRAY[@]}

FAILED_TESTS=0
PASSED_TESTS=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASSED_TESTS++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAILED_TESTS++))
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

section() {
    echo ""
    echo "=== $1 ==="
}

# Test 1: Storage
section "Storage Tests"

if mountpoint -q ${MOUNT_POINT}; then
    pass "BTRFS filesystem is mounted at ${MOUNT_POINT}"
else
    fail "BTRFS filesystem is NOT mounted at ${MOUNT_POINT}"
fi

if btrfs filesystem show ${MOUNT_POINT} | grep -qi "${BTRFS_RAID_LEVEL}"; then
    pass "BTRFS is using ${BTRFS_RAID_LEVEL}"
else
    fail "BTRFS is NOT using ${BTRFS_RAID_LEVEL}"
fi

# Check bcache
BCACHE_DEVICES=($(ls -d /sys/block/bcache* 2>/dev/null || true))
if [[ ${#BCACHE_DEVICES[@]} -gt 0 ]]; then
    # Get first bcache device name
    FIRST_BCACHE=$(basename "${BCACHE_DEVICES[0]}")
    BCACHE_MODE=$(cat /sys/block/${FIRST_BCACHE}/bcache/cache_mode 2>/dev/null || echo "unknown")
    if [[ "${BCACHE_MODE}" == *"writeback"* ]]; then
        pass "bcache is in writeback mode (${FIRST_BCACHE})"
    else
        warn "bcache mode: ${BCACHE_MODE} on ${FIRST_BCACHE} (expected: writeback)"
    fi
else
    warn "bcache devices not found"
fi

# Check directory structure
for dir in homes workspaces shared docker-volumes snapshots; do
    if [[ -d "${MOUNT_POINT}/${dir}" ]]; then
        pass "Directory exists: ${MOUNT_POINT}/${dir}"
    else
        fail "Directory missing: ${MOUNT_POINT}/${dir}"
    fi
done

# Test 2: GPU
section "GPU Tests"

if command -v nvidia-smi &> /dev/null; then
    pass "nvidia-smi is installed"

    if nvidia-smi &>/dev/null; then
        pass "GPU is detected"
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader)
        GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
        echo "  GPU: ${GPU_NAME}"
        echo "  Temperature: ${GPU_TEMP}°C"
    else
        fail "nvidia-smi failed to query GPU"
    fi
else
    fail "nvidia-smi is NOT installed"
fi

# Test 3: Docker
section "Docker Tests"

if command -v docker &> /dev/null; then
    pass "Docker is installed"
else
    fail "Docker is NOT installed"
fi

if systemctl is-active --quiet docker; then
    pass "Docker service is running"
else
    fail "Docker service is NOT running"
fi

# Test NVIDIA runtime
if docker run --rm --gpus all nvidia/cuda:latest nvidia-smi &>/dev/null; then
    pass "Docker NVIDIA runtime is working"
else
    fail "Docker NVIDIA runtime is NOT working"
fi

# Check running containers
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | wc -l)
HEALTHY_CONTAINERS=$(docker ps --filter "health=healthy" --format '{{.Names}}' | wc -l)
if [[ ${RUNNING_CONTAINERS} -gt 0 ]]; then
    if [[ ${HEALTHY_CONTAINERS} -gt 0 ]]; then
        pass "${HEALTHY_CONTAINERS} containers are healthy (${RUNNING_CONTAINERS} total running)"
    else
        pass "${RUNNING_CONTAINERS} containers are running (health check status unavailable or not configured)"
    fi
else
    warn "No containers are running"
fi

# Test 4: Networking
section "Network Tests"

if ping -c 1 8.8.8.8 &>/dev/null; then
    pass "Internet connectivity (IPv4)"
else
    fail "No internet connectivity"
fi

if systemctl is-active --quiet ufw; then
    pass "UFW firewall is active"
else
    warn "UFW is not active"
fi

if systemctl is-active --quiet cloudflared &>/dev/null; then
    pass "Cloudflare Tunnel is running"
else
    warn "Cloudflare Tunnel is not running"
fi

# Test 5: Monitoring
section "Monitoring Tests"

# Check Prometheus
if curl -s http://localhost:9090/-/healthy &>/dev/null; then
    pass "Prometheus is healthy"
else
    warn "Prometheus is not responding"
fi

# Check Grafana
if curl -s http://localhost:3000/api/health &>/dev/null; then
    pass "Grafana is healthy"
else
    warn "Grafana is not responding"
fi

# Check Netdata
if curl -s http://localhost:19999/api/v1/info &>/dev/null; then
    pass "Netdata is healthy"
else
    warn "Netdata is not responding"
fi

# Test 6: Backups
section "Backup Tests"

# Check BTRFS snapshots
SNAPSHOT_COUNT=$(ls -1 ${MOUNT_POINT}/snapshots 2>/dev/null | wc -l)
if [[ ${SNAPSHOT_COUNT} -gt 0 ]]; then
    pass "${SNAPSHOT_COUNT} BTRFS snapshots exist"
else
    warn "No BTRFS snapshots found"
fi

# Check Restic
if [[ -f /root/.restic-password ]]; then
    pass "Restic password file exists"

    # Check if BACKUP_REMOTE variable is set
    if [[ -z "${BACKUP_REMOTE:-}" ]]; then
        warn "BACKUP_REMOTE variable not set in config"
    else
        export RESTIC_PASSWORD_FILE=/root/.restic-password
        if restic -r "rclone:${BACKUP_REMOTE}" snapshots &>/dev/null; then
            RESTIC_COUNT=$(restic -r "rclone:${BACKUP_REMOTE}" snapshots --json 2>/dev/null | jq '. | length')
            pass "Restic repository is accessible (${RESTIC_COUNT} snapshots)"
        else
            warn "Cannot access Restic repository"
        fi
    fi
else
    warn "Restic not configured"
fi

# Test 7: Users
section "User Tests"

for user in ${USER_ARRAY[@]}; do
    if id "${user}" &>/dev/null; then
        pass "User ${user} exists"

        # Check home directory
        if [[ -d "${MOUNT_POINT}/homes/${user}" ]]; then
            pass "  Home directory exists for ${user}"
        else
            fail "  Home directory missing for ${user}"
        fi
    else
        fail "User ${user} does NOT exist"
    fi
done

# Test 8: Services
section "Service Tests"

SERVICES=(
    "traefik:8080"
    "netdata:19999"
    "prometheus:9090"
    "grafana:3000"
    "portainer:9000"
    "filebrowser:8081"
    "dozzle:8082"
    "tensorboard:6006"
)

for service in "${SERVICES[@]}"; do
    NAME="${service%%:*}"
    PORT="${service##*:}"

    if curl -s -o /dev/null -w "%{http_code}" http://localhost:${PORT} | grep -q "200\|302\|401"; then
        pass "${NAME} is responding on port ${PORT}"
    else
        warn "${NAME} is NOT responding on port ${PORT}"
    fi
done

# Test 9: Smart Monitoring
section "SMART Monitoring Tests"

if command -v smartctl &> /dev/null; then
    pass "smartmontools is installed"

    for disk in /dev/sd{a,b,c,d}; do
        if [[ -b "${disk}" ]]; then
            if smartctl -H ${disk} | grep -q "PASSED"; then
                pass "SMART status: ${disk} PASSED"
            else
                fail "SMART status: ${disk} FAILED"
            fi
        fi
    done
else
    fail "smartmontools is NOT installed"
fi

# Test 10: Cron Jobs
section "Cron Job Tests"

CRON_FILES=(
    "/etc/cron.d/btrfs-snapshots"
    "/etc/cron.d/restic-backup"
    "/etc/cron.d/ml-monitoring"
    "/etc/cron.d/customer-data-sync"
)

for cron_file in "${CRON_FILES[@]}"; do
    if [[ -f "${cron_file}" ]]; then
        pass "Cron file exists: $(basename ${cron_file})"
    else
        warn "Cron file missing: $(basename ${cron_file})"
    fi
done

# Summary
echo ""
echo "========================================="
echo "  Test Summary"
echo "========================================="
echo -e "${GREEN}Passed: ${PASSED_TESTS}${NC}"
echo -e "${RED}Failed: ${FAILED_TESTS}${NC}"
echo ""

if [[ ${FAILED_TESTS} -eq 0 ]]; then
    echo -e "${GREEN}All critical tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Review output above.${NC}"
    exit 1
fi
