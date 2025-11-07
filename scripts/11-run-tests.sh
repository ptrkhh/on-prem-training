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

# Install required dependencies for tests
echo "Installing test dependencies..."
apt-get update -qq && apt-get install -y -qq curl jq > /dev/null 2>&1 || true

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

COMPOSE_FILE_PATH="${SCRIPT_DIR}/../docker/docker-compose.yml"
COMPOSE_STATUS_STATE="unset"
COMPOSE_STATUS_JSON=""

http_status_ok() {
    case "$1" in
        200|201|204|301|302|401|403) return 0 ;;
        *) return 1 ;;
    esac
}

load_compose_status() {
    if [[ "${COMPOSE_STATUS_STATE}" != "unset" ]]; then
        return
    fi

    if [[ ! -f "${COMPOSE_FILE_PATH}" ]]; then
        COMPOSE_STATUS_STATE="missing_file"
        return
    fi

    local output
    if output=$(docker compose -f "${COMPOSE_FILE_PATH}" ps --format json 2>/dev/null); then
        COMPOSE_STATUS_STATE="ok"
        COMPOSE_STATUS_JSON="${output}"
    else
        COMPOSE_STATUS_STATE="error"
        COMPOSE_STATUS_JSON=""
    fi
}

docker_service_running() {
    local service_name="$1"
    load_compose_status

    case "${COMPOSE_STATUS_STATE}" in
        ok)
            local state
            state=$(echo "${COMPOSE_STATUS_JSON}" | jq -r ".[] | select(.Service==\"${service_name}\") | .State // empty")
            if [[ -z "${state}" ]]; then
                return 2
            fi
            if [[ "${state}" == "running" ]]; then
                return 0
            else
                return 1
            fi
            ;;
        missing_file|error)
            return 3
            ;;
        *)
            return 3
            ;;
    esac
}

check_route_service() {
    local display_name="$1"
    local host_prefix="$2"
    local compose_service="$3"
    local route_path="${4:-/}"

    if [[ -n "${DOMAIN}" ]]; then
        local fqdn="${host_prefix}.${DOMAIN}"
        local status_code
        status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --resolve "${fqdn}:80:127.0.0.1" "http://${fqdn}${route_path}" 2>/dev/null)
        status_code=${status_code:-000}

        if http_status_ok "${status_code}"; then
            pass "${display_name} reachable via http://${fqdn}${route_path}"
            return
        fi

        docker_service_running "${compose_service}"
        local service_state=$?
        case "${service_state}" in
            0)
                fail "${display_name} route http://${fqdn}${route_path} returned status ${status_code}"
                ;;
            1)
                fail "${display_name} container is not running (HTTP status ${status_code})"
                ;;
            2)
                warn "${display_name} not found in docker compose output (HTTP status ${status_code})"
                ;;
            3)
                warn "${display_name} route http://${fqdn}${route_path} returned status ${status_code} (docker compose status unavailable)"
                ;;
        esac
    else
        docker_service_running "${compose_service}"
        local service_state=$?
        case "${service_state}" in
            0)
                pass "${display_name} container running (DOMAIN not set; skipped HTTP check)"
                ;;
            1)
                fail "${display_name} container is not running (DOMAIN not set)"
                ;;
            2)
                warn "${display_name} not found in docker compose output (DOMAIN not set)"
                ;;
            3)
                warn "${display_name} skipped (DOMAIN not set and docker compose status unavailable)"
                ;;
        esac
    fi
}

# Test 1: Storage
section "Storage Tests"

if mountpoint -q ${MOUNT_POINT}; then
    pass "BTRFS filesystem is mounted at ${MOUNT_POINT}"
else
    fail "BTRFS filesystem is NOT mounted at ${MOUNT_POINT}"
fi

# Parse BTRFS RAID level more robustly with awk
# Try primary method
ACTUAL_RAID=$(btrfs filesystem df ${MOUNT_POINT} | awk '/^Data/ {gsub(/[,:]/, ""); print tolower($2)}')

# Fallback: check device stats
if [[ -z "${ACTUAL_RAID}" ]]; then
    ACTUAL_RAID=$(btrfs fi usage ${MOUNT_POINT} 2>/dev/null | grep -i "Data.*RAID" | sed -E 's/.*RAID([0-9]+).*/raid\1/' | head -1)
fi

# Fallback: check fi show
if [[ -z "${ACTUAL_RAID}" ]]; then
    warn "Could not detect RAID level from 'btrfs filesystem df'"
    ACTUAL_RAID="unknown"
fi

EXPECTED_RAID=$(echo "${BTRFS_RAID_LEVEL}" | tr '[:upper:]' '[:lower:]')

if [[ "${ACTUAL_RAID}" == "unknown" ]]; then
    warn "Could not auto-detect RAID level - manual verification required"
    echo "  Expected: ${EXPECTED_RAID}"
    echo "  Manual check: btrfs filesystem df ${MOUNT_POINT}"
    echo "  This is a test limitation, not necessarily a configuration issue"
else
    if [[ "${ACTUAL_RAID}" == "${EXPECTED_RAID}" ]]; then
        pass "BTRFS is using ${BTRFS_RAID_LEVEL} (detected: ${ACTUAL_RAID})"
    else
        fail "BTRFS is NOT using ${BTRFS_RAID_LEVEL} (detected: ${ACTUAL_RAID})"
    fi
fi

# Check bcache
BCACHE_DEVICES=($(ls -d /sys/block/bcache* 2>/dev/null || true))
if [[ ${#BCACHE_DEVICES[@]} -gt 0 ]]; then
    # Get first bcache device name
    FIRST_BCACHE=$(basename "${BCACHE_DEVICES[0]}")
    ACTUAL_BCACHE_MODE=$(cat /sys/block/${FIRST_BCACHE}/bcache/cache_mode 2>/dev/null || echo "unknown")

    # Get configured bcache mode from config.sh (default to writeback if not set)
    EXPECTED_BCACHE_MODE="${BCACHE_MODE:-writeback}"

    # Extract the actual mode from the format "[writeback] writethrough writearound none"
    CURRENT_MODE=$(echo "${ACTUAL_BCACHE_MODE}" | grep -o '\[.*\]' | tr -d '[]')

    if [[ "${CURRENT_MODE}" == "${EXPECTED_BCACHE_MODE}" ]]; then
        pass "bcache is in ${EXPECTED_BCACHE_MODE} mode (${FIRST_BCACHE})"
    else
        warn "bcache mode: ${CURRENT_MODE} on ${FIRST_BCACHE} (expected: ${EXPECTED_BCACHE_MODE})"
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

# Test 2: Google Drive Mounts
section "Google Drive Mount Tests"

# Check if Google Drive mounts are configured
if [[ -n "${GOOGLE_DRIVE_MOUNTS:-}" ]]; then
    # Parse Google Drive mount configuration (format: "user1:folder1,user2:folder2")
    IFS=',' read -ra MOUNT_PAIRS <<< "${GOOGLE_DRIVE_MOUNTS}"
    for mount_pair in "${MOUNT_PAIRS[@]}"; do
        user="${mount_pair%%:*}"
        folder="${mount_pair##*:}"

        # Check if rclone remote exists
        if rclone listremotes 2>/dev/null | grep -q "gdrive-${user}:"; then
            pass "Google Drive remote configured for ${user}"

            # Check if mount point exists and is mounted
            MOUNT_PATH="${MOUNT_POINT}/homes/${user}/GoogleDrive"
            if [[ -d "${MOUNT_PATH}" ]]; then
                # Check if actually mounted (look for .rclone-health file or test mount)
                if mountpoint -q "${MOUNT_PATH}" 2>/dev/null || findmnt "${MOUNT_PATH}" &>/dev/null; then
                    pass "  Google Drive mounted at ${MOUNT_PATH}"

                    # Test read access
                    if timeout 5 ls "${MOUNT_PATH}" &>/dev/null; then
                        pass "  Google Drive mount is accessible"
                    else
                        fail "  Google Drive mount is not responding"
                    fi
                else
                    warn "  Google Drive directory exists but is not mounted"
                fi
            else
                fail "  Mount point missing: ${MOUNT_PATH}"
            fi
        else
            warn "Google Drive remote not configured for ${user}"
        fi
    done
else
    warn "No Google Drive mounts configured (GOOGLE_DRIVE_MOUNTS not set)"
fi

# Test 3: GPU
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

# Pre-pull required Docker images to avoid hangs during tests
echo "Pulling required Docker images..."
if docker pull nvidia/cuda:latest &>/dev/null; then
    pass "Docker image nvidia/cuda:latest pulled successfully"
else
    warn "Failed to pull nvidia/cuda:latest - test may hang or fail"
fi

# Test NVIDIA runtime
if docker run --rm --gpus all nvidia/cuda:latest nvidia-smi &>/dev/null; then
    pass "Docker NVIDIA runtime is working"
else
    fail "Docker NVIDIA runtime is NOT working"
fi

# Test GPU access from user containers
if [[ ${USER_COUNT} -gt 0 ]]; then
    TEST_USER="${USER_ARRAY[0]}"
    USER_CONTAINER=$(docker ps --filter "name=${TEST_USER}" --format '{{.Names}}' | head -1)

    if [[ -n "${USER_CONTAINER}" ]]; then
        # Check if container has GPU access
        if docker exec "${USER_CONTAINER}" nvidia-smi &>/dev/null 2>&1; then
            pass "User container ${USER_CONTAINER} has GPU access"

            # Get GPU info from container
            GPU_COUNT=$(docker exec "${USER_CONTAINER}" nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1)
            if [[ -n "${GPU_COUNT}" && "${GPU_COUNT}" -gt 0 ]]; then
                pass "  ${GPU_COUNT} GPU(s) accessible from user container"
            fi
        else
            warn "User container ${USER_CONTAINER} does not have GPU access (check if --gpus flag is set)"
        fi
    else
        # Try creating a temporary test container with GPU access
        if docker run --rm --gpus all --name test-gpu-access-$$ nvidia/cuda:latest nvidia-smi &>/dev/null 2>&1; then
            pass "GPU access verified via test container"
        else
            warn "Could not verify GPU access in user containers (no user containers running)"
        fi
    fi
else
    warn "Skipping user container GPU test (no users configured)"
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

# Test 5: Networking
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

# Test 6: Monitoring
section "Monitoring Tests"

# Check Prometheus, Grafana, Netdata via Traefik
check_route_service "Prometheus" "prometheus" "prometheus" "/-/healthy"
check_route_service "Grafana" "grafana" "grafana" "/api/health"
check_route_service "Netdata" "health" "netdata" "/api/v1/info"

# Test 7: Backups
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

# Test 8: Users
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

# Test 9: User Container Functionality
section "User Container Tests"

# Test if user containers can be created and accessed
if [[ ${USER_COUNT} -gt 0 ]]; then
    TEST_USER="${USER_ARRAY[0]}"

    # Check if user has a container running
    USER_CONTAINER=$(docker ps --filter "name=${TEST_USER}" --format '{{.Names}}' | head -1)

    if [[ -n "${USER_CONTAINER}" ]]; then
        pass "Container exists for user ${TEST_USER}: ${USER_CONTAINER}"

        # Test container health
        CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "${USER_CONTAINER}" 2>/dev/null)
        if [[ "${CONTAINER_STATUS}" == "running" ]]; then
            pass "  Container is running"

            # Test if we can execute commands in the container
            if docker exec "${USER_CONTAINER}" echo "test" &>/dev/null; then
                pass "  Can execute commands in container"

                # Test if home directory is mounted correctly
                if docker exec "${USER_CONTAINER}" test -d "/home/${TEST_USER}" 2>/dev/null; then
                    pass "  Home directory is accessible in container"
                else
                    fail "  Home directory not accessible in container"
                fi

                # Test if workspace is mounted
                if docker exec "${USER_CONTAINER}" test -d "/workspace" 2>/dev/null; then
                    pass "  Workspace directory is accessible in container"
                else
                    warn "  Workspace directory not found in container"
                fi
            else
                fail "  Cannot execute commands in container"
            fi
        else
            fail "  Container is not running (status: ${CONTAINER_STATUS})"
        fi
    else
        warn "No container found for user ${TEST_USER} (this may be expected if containers are created on-demand)"
    fi
else
    warn "No users configured to test containers"
fi

# Test 10: Services
section "Service Tests"

TRAEFIK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:${TRAEFIK_PORT:-8080}" 2>/dev/null)
TRAEFIK_STATUS=${TRAEFIK_STATUS:-000}
if http_status_ok "${TRAEFIK_STATUS}"; then
    pass "Traefik dashboard responding on port ${TRAEFIK_PORT:-8080}"
else
    warn "Traefik dashboard is NOT responding on port ${TRAEFIK_PORT:-8080} (status ${TRAEFIK_STATUS})"
fi

SERVICE_ROUTES=(
    "Netdata|health|netdata"
    "Prometheus|prometheus|prometheus"
    "Grafana|grafana|grafana"
    "Portainer|portainer|portainer"
    "File Browser|files|filebrowser"
    "Dozzle|logs|dozzle"
    "TensorBoard|tensorboard|tensorboard"
    "Guacamole|guacamole|guacamole"
)

for entry in "${SERVICE_ROUTES[@]}"; do
    IFS='|' read -r DISPLAY_NAME ROUTE_HOST COMPOSE_SERVICE <<< "${entry}"
    check_route_service "${DISPLAY_NAME}" "${ROUTE_HOST}" "${COMPOSE_SERVICE}"
done

# Test 11: Smart Monitoring
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

# Test 12: Cron Jobs
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
