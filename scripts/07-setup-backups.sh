#!/bin/bash
set -euo pipefail

# ML Training Server - Backup Setup Script
# Configures BTRFS snapshots and Restic backups to GDrive

echo "=== Backup Setup ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example"
    exit 1
fi

source "${CONFIG_FILE}"
SNAPSHOT_DIR="${MOUNT_POINT}/snapshots"
SCRIPTS_DIR="/opt/scripts/backup"

# Install required packages
echo "Installing required packages..."
apt update
apt install -y restic rclone bc mailutils jq

# Step 1: Setup rclone for GDrive
echo ""
echo "=== Step 1: Validating rclone configuration for Google Drive ==="
echo ""

# Extract remote name from BACKUP_REMOTE (format: "remotename:path")
REMOTE_NAME=$(echo "${BACKUP_REMOTE}" | cut -d: -f1)

# Validate rclone config exists
if ! rclone config show "${REMOTE_NAME}" &>/dev/null; then
    echo "ERROR: rclone remote '${REMOTE_NAME}' is not configured"
    echo "Please run: rclone config"
    echo "Create a new remote named '${REMOTE_NAME}' with the appropriate backend"
    echo "Then run this script again."
    exit 1
fi

echo "✓ rclone remote '${REMOTE_NAME}' configuration found"

# Verify rclone config works by testing connectivity
echo "Testing remote storage connectivity..."
if ! rclone lsd ${REMOTE_NAME}: --max-depth 1 &>/dev/null; then
    echo "ERROR: Cannot access remote storage '${REMOTE_NAME}' via rclone"
    echo "The remote is configured but connectivity test failed."
    echo "Possible issues:"
    echo "  - OAuth token expired (run: rclone config reconnect ${REMOTE_NAME}:)"
    echo "  - Network connectivity issues"
    echo "  - Insufficient permissions"
    exit 1
fi

echo "✓ rclone configured and working successfully"

# Step 2: Create backup scripts directory
echo ""
echo "=== Step 2: Creating backup scripts ==="

mkdir -p ${SCRIPTS_DIR}

# BTRFS Snapshot Script
cat > ${SCRIPTS_DIR}/create-snapshot.sh <<EOF
#!/bin/bash
set -euo pipefail

MOUNT_POINT="${MOUNT_POINT}"
SNAPSHOT_DIR="\${MOUNT_POINT}/snapshots"
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
SNAPSHOT_TYPE="\$1"  # hourly, daily, weekly

# Create snapshot
SNAPSHOT_NAME="\${SNAPSHOT_TYPE}_\${TIMESTAMP}"
btrfs subvolume snapshot -r \${MOUNT_POINT} \${SNAPSHOT_DIR}/\${SNAPSHOT_NAME}

echo "Created snapshot: \${SNAPSHOT_NAME}"

# Cleanup old snapshots
case "\${SNAPSHOT_TYPE}" in
    hourly)
        # Keep last 24 hourly snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'hourly_*' -type d | sort -r | tail -n +25 | xargs -r rm -rf
        ;;
    daily)
        # Keep last 7 daily snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'daily_*' -type d | sort -r | tail -n +8 | xargs -r rm -rf
        ;;
    weekly)
        # Keep last 4 weekly snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'weekly_*' -type d | sort -r | tail -n +5 | xargs -r rm -rf
        ;;
esac

echo "Cleaned up old \${SNAPSHOT_TYPE} snapshots"
EOF

chmod +x ${SCRIPTS_DIR}/create-snapshot.sh

# Restic Initialization Script
cat > ${SCRIPTS_DIR}/init-restic.sh <<EOF
#!/bin/bash
set -euo pipefail

RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE}"
RESTIC_PASSWORD_FILE="/root/.restic-password"

# Generate random password if doesn't exist
if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
    openssl rand -base64 32 > ${RESTIC_PASSWORD_FILE}
    chmod 600 ${RESTIC_PASSWORD_FILE}
    echo "Generated Restic password: ${RESTIC_PASSWORD_FILE}"
    echo "IMPORTANT: Back up this password file!"
fi

export RESTIC_PASSWORD_FILE

# Test rclone connection if using rclone backend
if [[ "\${RESTIC_REPOSITORY}" =~ ^rclone: ]]; then
    REMOTE_NAME=\$(echo "\${RESTIC_REPOSITORY}" | sed 's/rclone://' | cut -d: -f1)
    if ! rclone lsd "\${REMOTE_NAME}:" &>/dev/null; then
        echo "ERROR: Cannot access rclone remote '\${REMOTE_NAME}'. Check 'rclone config' and network connectivity"
        exit 1
    fi
fi

# Initialize repository
if ! restic -r ${RESTIC_REPOSITORY} snapshots &>/dev/null; then
    echo "Initializing Restic repository..."
    restic -r ${RESTIC_REPOSITORY} init
    echo "Restic repository initialized"
else
    echo "Restic repository already exists"
fi

# Test connection
restic -r ${RESTIC_REPOSITORY} snapshots
EOF

chmod +x ${SCRIPTS_DIR}/init-restic.sh

# Restic Backup Script
cat > ${SCRIPTS_DIR}/restic-backup.sh <<EOF
#!/bin/bash
set -euo pipefail

RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE}"
RESTIC_PASSWORD_FILE="/root/.restic-password"
MOUNT_POINT="${MOUNT_POINT}"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
LOG_FILE="/var/log/restic-backup.log"
BACKUP_STATUS="success"

export RESTIC_PASSWORD_FILE

# Check disk space before backup
echo "Checking disk space..."
AVAILABLE_GB=\$(df -BG "\${MOUNT_POINT}" | tail -1 | awk '{print \$4}' | sed 's/G//')
MIN_SPACE_GB=10

if [[ \${AVAILABLE_GB} -lt \${MIN_SPACE_GB} ]]; then
    echo "ERROR: Insufficient disk space for backup!"
    echo "Available: \${AVAILABLE_GB}GB, Required: \${MIN_SPACE_GB}GB"
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "critical" "Backup failed: Low disk space (\${AVAILABLE_GB}GB available)"
    fi
    exit 1
fi
echo "Disk space check passed: \${AVAILABLE_GB}GB available"

# Cleanup trap to unlock on failure
cleanup() {
    if [[ "\${BACKUP_STATUS}" == "failed" ]]; then
        echo "Attempting to unlock repository..."
        restic -r \${RESTIC_REPOSITORY} unlock || true
    fi
}
trap cleanup EXIT

# Redirect all output to log file
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "=== Restic Backup Started: $(date) ==="

# Verify repository access before pausing containers
echo "Verifying repository access..."
if ! restic -r ${RESTIC_REPOSITORY} snapshots &>/dev/null; then
    echo "ERROR: Cannot access restic repository!"
    echo "Check network connectivity and rclone authentication"
    exit 1
fi

# Pause all workspace containers to ensure consistency
echo "Pausing all workspace containers..."
PAUSED_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -E 'workspace' || true)
PAUSE_FAILURES=""
if [[ -n "${PAUSED_CONTAINERS}" ]]; then
    for container in ${PAUSED_CONTAINERS}; do
        echo "  Pausing ${container}..."
        if ! docker pause "${container}" 2>/dev/null; then
            PAUSE_FAILURES="${PAUSE_FAILURES} ${container}"
            echo "    WARNING: Failed to pause ${container}"
        fi
    done
fi

if [[ -n "${PAUSE_FAILURES}" ]]; then
    echo "ERROR: Failed to pause containers:${PAUSE_FAILURES}"
    echo "Cannot proceed with backup - inconsistent state may cause data corruption"
    echo "Unpausing containers that were successfully paused..."
    for container in ${PAUSED_CONTAINERS}; do
        if ! echo "${PAUSE_FAILURES}" | grep -q "${container}"; then
            docker unpause "${container}" 2>/dev/null || true
        fi
    done
    exit 1
fi

# Validate backup directories exist
for dir in "\${MOUNT_POINT}/homes" "\${MOUNT_POINT}/docker-volumes" "\${MOUNT_POINT}/shared/tensorboard"; do
    if [[ ! -d "\${dir}" ]]; then
        echo "WARNING: Backup directory does not exist: \${dir}"
    fi
done

# Run backup with bandwidth limit
BANDWIDTH_LIMIT_KBPS=\$((${BACKUP_BANDWIDTH_LIMIT_MBPS} * 1000 / 8))
echo "Running backup (${BACKUP_BANDWIDTH_LIMIT_MBPS} Mbps limit)..."
if restic -r \${RESTIC_REPOSITORY} backup \
    --verbose \
    --tag daily \
    --limit-upload \${BANDWIDTH_LIMIT_KBPS} \
    \${MOUNT_POINT}/homes \
    \${MOUNT_POINT}/docker-volumes \
    \${MOUNT_POINT}/shared/tensorboard; then

    echo "Backup completed successfully"
    BACKUP_STATUS="success"
else
    echo "ERROR: Backup failed!"
    BACKUP_STATUS="failed"
fi

# Resume Docker containers
echo "Resuming Docker containers..."
if [[ -n "${PAUSED_CONTAINERS}" ]]; then
    for container in ${PAUSED_CONTAINERS}; do
        docker unpause "${container}" || true
    done
fi

# Cleanup old backups (keep 7 daily, 52 weekly)
echo "Pruning old backups..."
restic -r ${RESTIC_REPOSITORY} forget \
    --keep-daily 7 \
    --keep-weekly 52 \
    --prune

# Send alert if backup failed
if [[ "${BACKUP_STATUS}" == "failed" ]] && [[ -x "${ALERT_SCRIPT}" ]]; then
    ${ALERT_SCRIPT} "critical" "Restic backup failed! Check ${LOG_FILE}"
fi

# Send healthcheck ping
if [[ -f /root/.healthchecks-url ]]; then
    HEALTHCHECK_URL=$(cat /root/.healthchecks-url)
    if [[ "${BACKUP_STATUS}" == "success" ]]; then
        curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}" > /dev/null || true
    else
        curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}/fail" > /dev/null || true
    fi
fi

echo "=== Restic Backup Finished: $(date) ==="
echo ""
EOF

chmod +x ${SCRIPTS_DIR}/restic-backup.sh

# Restic Restore Verification Script
cat > ${SCRIPTS_DIR}/verify-restore.sh <<EOF
#!/bin/bash
set -euo pipefail

RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE}"
RESTIC_PASSWORD_FILE="/root/.restic-password"
RESTORE_DIR="/tmp/restore-test"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

export RESTIC_PASSWORD_FILE

# Ensure cleanup on exit
cleanup() {
    rm -rf "\${RESTORE_DIR}"
}
trap cleanup EXIT

echo "=== Restic Restore Verification: $(date) ==="

# Clean restore directory
rm -rf ${RESTORE_DIR}
mkdir -p ${RESTORE_DIR}

# Get latest snapshot
LATEST_SNAPSHOT=$(restic -r ${RESTIC_REPOSITORY} snapshots --json | jq -r '.[-1].id')

if [[ -z "${LATEST_SNAPSHOT}" ]]; then
    echo "ERROR: No snapshots found!"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "critical" "Restic restore verification failed: No snapshots"
    exit 1
fi

echo "Latest snapshot: ${LATEST_SNAPSHOT}"

# Restore a small subset for verification
echo "Restoring sample files..."
if restic -r ${RESTIC_REPOSITORY} restore ${LATEST_SNAPSHOT} \
    --target ${RESTORE_DIR} \
    --include '/homes/*/.*' \
    --include '/docker-volumes/*'; then

    echo "Restore verification successful"
    VERIFY_STATUS="success"
else
    echo "ERROR: Restore verification failed!"
    VERIFY_STATUS="failed"
fi

# Cleanup
rm -rf ${RESTORE_DIR}

# Send alert if verification failed
if [[ "${VERIFY_STATUS}" == "failed" ]] && [[ -x "${ALERT_SCRIPT}" ]]; then
    ${ALERT_SCRIPT} "critical" "Restic restore verification failed!"
fi

echo "=== Restore Verification Finished: $(date) ==="
EOF

chmod +x ${SCRIPTS_DIR}/verify-restore.sh

# Step 3: Initialize Restic repository
echo ""
echo "=== Step 3: Initializing Restic repository ==="
${SCRIPTS_DIR}/init-restic.sh

# Step 4: Setup cron jobs
echo ""
echo "=== Step 4: Setting up cron jobs ==="

# BTRFS snapshots
cat > /etc/cron.d/btrfs-snapshots <<EOF
# Hourly snapshots (every hour)
0 * * * * root ${SCRIPTS_DIR}/create-snapshot.sh hourly

# Daily snapshots (at 2 AM)
0 2 * * * root ${SCRIPTS_DIR}/create-snapshot.sh daily

# Weekly snapshots (Sunday at 3 AM)
0 3 * * 0 root ${SCRIPTS_DIR}/create-snapshot.sh weekly
EOF

# Restic backups
cat > /etc/cron.d/restic-backup <<EOF
# Daily backup (at 6 AM)
0 6 * * * root ${SCRIPTS_DIR}/restic-backup.sh

# Monthly restore verification (1st of month at 8 AM)
0 8 1 * * root ${SCRIPTS_DIR}/verify-restore.sh
EOF

echo "Cron jobs configured"

# Step 5: Setup healthchecks.io (optional)
echo ""
read -p "Do you want to set up healthchecks.io monitoring? (y/n): " setup_healthcheck

if [[ "$setup_healthcheck" == "y" ]]; then
    echo "Create a check at https://healthchecks.io/"
    echo "Then paste the ping URL here:"
    read -p "Ping URL: " healthcheck_url
    echo "${healthcheck_url}" > /root/.healthchecks-url
    chmod 600 /root/.healthchecks-url
    echo "healthchecks.io configured"
fi

# Step 6: Run initial backup test
echo ""
read -p "Run initial backup test now? (y/n): " run_test

if [[ "$run_test" == "y" ]]; then
    echo "Running initial backup..."
    ${SCRIPTS_DIR}/restic-backup.sh
fi

echo ""
echo "=== Backup Setup Complete ==="
echo ""
echo "Backup schedule:"
echo "  - BTRFS snapshots: Hourly, Daily (2 AM), Weekly (Sun 3 AM)"
echo "  - Restic to GDrive: Daily (6 AM)"
echo "  - Restore verification: Monthly (1st at 8 AM)"
echo ""
echo "Retention:"
echo "  - BTRFS: 24 hourly, 7 daily, 4 weekly"
echo "  - Restic: 7 daily, 52 weekly"
echo ""
echo "Restic password: /root/.restic-password"
echo ""
echo "=========================================="
echo "IMPORTANT: Restic password is: $(cat /root/.restic-password)"
echo "Store this securely - it's required to restore backups!"
echo "=========================================="
echo ""
echo "Manual commands:"
echo "  Create snapshot: ${SCRIPTS_DIR}/create-snapshot.sh daily"
echo "  Run backup: ${SCRIPTS_DIR}/restic-backup.sh"
echo "  List snapshots: restic -r ${BACKUP_REMOTE} snapshots"
echo "  Verify restore: ${SCRIPTS_DIR}/verify-restore.sh"
echo ""
