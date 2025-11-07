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

# Define restic cache directory (for deduplication and performance)
BACKUP_CACHE_DIR="${MOUNT_POINT}/cache/restic"
mkdir -p "${BACKUP_CACHE_DIR}"

# Define directories to include in backups
BACKUP_SOURCES=(
    "${MOUNT_POINT}/homes"
    "${MOUNT_POINT}/docker-volumes"
    "${MOUNT_POINT}/shared/tensorboard"
    "${MOUNT_POINT}/shared/datasets"
)

SHARED_DIR="${MOUNT_POINT}/shared"

if [[ ! -d "${SHARED_DIR}" ]]; then
    echo "ERROR: Expected shared directory not found at ${SHARED_DIR}"
    echo "Please run scripts/02-setup-gdrive-shared.sh before configuring backups."
    exit 1
fi

if ! mountpoint -q "${SHARED_DIR}"; then
    echo "ERROR: ${SHARED_DIR} is not mounted."
    echo "Google Drive mirroring is required for backups. Run scripts/02-setup-gdrive-shared.sh and ensure gdrive-shared.service is active."
    exit 1
fi

SHARED_FSTYPE=$(findmnt -n -o FSTYPE "${SHARED_DIR}" 2>/dev/null || echo "")
if [[ "${SHARED_FSTYPE}" != "fuse.rclone" ]]; then
    echo "ERROR: ${SHARED_DIR} must be mounted via rclone (fuse.rclone), found '${SHARED_FSTYPE:-unknown}'."
    echo "Re-run scripts/02-setup-gdrive-shared.sh to configure the Google Drive mount."
    exit 1
fi

# Load common functions
COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
    source "${COMMON_LIB}"
fi

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

# Check network connectivity (required for remote backups)
if ! check_network 3; then
    echo "ERROR: This script requires internet connectivity to:"
    echo "  - Access remote backup storage"
    echo "  - Initialize restic repository"
    echo "  - Verify rclone remote access"
    exit 1
fi

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
        # Keep last ${SNAPSHOT_KEEP_HOURLY} hourly snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'hourly_*' -type d | sort -r | tail -n +$((${SNAPSHOT_KEEP_HOURLY} + 1)) | xargs -r rm -rf
        ;;
    daily)
        # Keep last ${SNAPSHOT_KEEP_DAILY} daily snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'daily_*' -type d | sort -r | tail -n +$((${SNAPSHOT_KEEP_DAILY} + 1)) | xargs -r rm -rf
        ;;
    weekly)
        # Keep last ${SNAPSHOT_KEEP_WEEKLY} weekly snapshots
        find \${SNAPSHOT_DIR} -maxdepth 1 -name 'weekly_*' -type d | sort -r | tail -n +$((${SNAPSHOT_KEEP_WEEKLY} + 1)) | xargs -r rm -rf
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
    if ! restic -r ${RESTIC_REPOSITORY} init 2>&1 | tee /tmp/restic-init-error.log; then
        ERROR_MSG=\$(cat /tmp/restic-init-error.log)
        echo "ERROR: Failed to initialize Restic repository"
        echo "Error details: \${ERROR_MSG}"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Verify rclone remote is accessible: rclone lsd \${REMOTE_NAME}:"
        echo "  2. Check network connectivity"
        echo "  3. Verify credentials are valid"
        echo "  4. Check remote storage has sufficient space"
        exit 1
    fi
    echo "Restic repository initialized successfully"
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

# Calculate source data size
echo "Calculating backup size requirements..."
SOURCE_SIZE_GB=\$(du -sb ${BACKUP_SOURCES[@]} 2>/dev/null | awk '{sum+=\$1} END {print int(sum/1024/1024/1024)+1}')

# Determine if this is initial or incremental backup
if [ ! -d "\${BACKUP_CACHE_DIR}/snapshots" ]; then
    # First backup needs more space (compression ratio ~0.6)
    REQUIRED_GB=\$((SOURCE_SIZE_GB * 60 / 100 + 5))  # 60% + 5GB safety margin
    BACKUP_TYPE="initial"
else
    # Incremental backups need less space due to deduplication
    REQUIRED_GB=\$((SOURCE_SIZE_GB * 10 / 100 + 2))  # 10% + 2GB for incremental
    BACKUP_TYPE="incremental"
fi

# Check available space
AVAILABLE_GB=\$(df -BG "\${BACKUP_CACHE_DIR}" | tail -1 | awk '{print \$4}' | sed 's/G//')

if [[ \${AVAILABLE_GB} -lt \${REQUIRED_GB} ]]; then
    echo "ERROR: Insufficient space for \${BACKUP_TYPE} backup!"
    echo "  Source data: \${SOURCE_SIZE_GB}GB"
    echo "  Required: \${REQUIRED_GB}GB"
    echo "  Available: \${AVAILABLE_GB}GB"
    echo "  Shortfall: \$((REQUIRED_GB - AVAILABLE_GB))GB"
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "critical" "Backup failed: Insufficient space (\${AVAILABLE_GB}GB available, \${REQUIRED_GB}GB required)"
    fi
    exit 1
fi

echo "Disk space check passed: \${AVAILABLE_GB}GB available, \${REQUIRED_GB}GB required for \${BACKUP_TYPE} backup"

# Warn if available space is less than 2x required (helps predict future failures)
if [[ \${AVAILABLE_GB} -lt \$((REQUIRED_GB * 2)) ]]; then
    echo "WARNING: Available space (\${AVAILABLE_GB}GB) is less than 2x required (\${REQUIRED_GB}GB)"
    echo "  Consider freeing up space to avoid future backup failures"
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "warning" "Backup space low: \${AVAILABLE_GB}GB available, consider cleanup"
    fi
fi

# Initialize backup status and repository lock tracking
BACKUP_STATUS="not_started"
REPO_LOCKED=false

# Cleanup trap to unlock on failure or interruption
cleanup() {
    if [[ "\${BACKUP_STATUS}" != "success" && "\${REPO_LOCKED}" == "true" ]]; then
        echo "Attempting to unlock repository..."
        restic -r \${RESTIC_REPOSITORY} unlock 2>&1 | tee -a "\${LOG_FILE}" || true
    fi
}

# Register cleanup for all exit scenarios
trap cleanup EXIT INT TERM

# Redirect all output to log file
exec > >(tee -a \${LOG_FILE}) 2>&1

echo "=== Restic Backup Started: \$(date) ==="

# Verify repository access before pausing containers
echo "Verifying repository access..."
if ! restic -r \${RESTIC_REPOSITORY} snapshots &>/dev/null; then
    echo "ERROR: Cannot access restic repository!"
    echo "Check network connectivity and rclone authentication"
    exit 1
fi

# Validate backup directories exist
echo "Validating backup directories..."
MISSING_DIRS=""
for dir in "\${BACKUP_SOURCES[@]}"; do
    if [[ ! -d "\${dir}" ]]; then
        echo "ERROR: Required backup directory does not exist: \${dir}"
        MISSING_DIRS="\${MISSING_DIRS} \${dir}"
    else
        echo "  ✓ \${dir}"
    fi
done

if [[ -n "\${MISSING_DIRS}" ]]; then
    echo "ERROR: Cannot proceed with backup - missing required directories:"
    echo "\${MISSING_DIRS}"
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "critical" "Backup failed: Missing directories - \${MISSING_DIRS}"
    fi
    exit 1
fi
echo "All backup directories verified"

# Create BTRFS snapshot for consistent backup (read-only snapshot, no service interruption)
echo "Creating BTRFS snapshot for backup..."
SNAPSHOT_DIR="\${MOUNT_POINT}/snapshots"
SNAPSHOT_NAME="backup_\$(date +%Y%m%d_%H%M%S)"
SNAPSHOT_PATH="\${SNAPSHOT_DIR}/\${SNAPSHOT_NAME}"

if ! btrfs subvolume snapshot -r "\${MOUNT_POINT}" "\${SNAPSHOT_PATH}"; then
    echo "ERROR: Failed to create BTRFS snapshot!"
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "critical" "Backup failed: Could not create BTRFS snapshot"
    fi
    exit 1
fi
echo "Created snapshot: \${SNAPSHOT_NAME}"

# Run backup from snapshot (no need to pause containers)
# Backup runs from read-only snapshot, containers continue running normally
BANDWIDTH_LIMIT_KBPS=\$((${BACKUP_BANDWIDTH_LIMIT_MBPS} * 1000 / 8))
SNAPSHOT_SOURCES=()
for source in "\${BACKUP_SOURCES[@]}"; do
    if [[ "\${source}" == "\${MOUNT_POINT}"* ]]; then
        relative_path="\${source#\${MOUNT_POINT}/}"
        SNAPSHOT_SOURCES+=("\${SNAPSHOT_PATH}/\${relative_path}")
    else
        echo "WARNING: Skipping backup source outside mount point: \${source}"
    fi
done

if [[ \${#SNAPSHOT_SOURCES[@]} -eq 0 ]]; then
    echo "ERROR: No snapshot sources resolved for backup."
    exit 1
fi
echo "Running backup from snapshot (\${BACKUP_BANDWIDTH_LIMIT_MBPS} Mbps limit)..."

# Mark repository as locked before backup starts
REPO_LOCKED=true

if restic -r \${RESTIC_REPOSITORY} backup \
    --verbose \
    --tag daily \
    --limit-upload \${BANDWIDTH_LIMIT_KBPS} \
    "\${SNAPSHOT_SOURCES[@]}"; then

    echo "Backup completed successfully"
    BACKUP_STATUS="success"
    REPO_LOCKED=false
else
    echo "ERROR: Backup failed!"
    BACKUP_STATUS="failed"
fi

# Cleanup backup snapshot (free space after backup)
echo "Cleaning up backup snapshot..."
btrfs subvolume delete "\${SNAPSHOT_PATH}" || echo "WARNING: Failed to delete snapshot, manual cleanup may be needed"

# Cleanup old backups (keep 7 daily, 52 weekly)
echo "Pruning old backups..."
restic -r \${RESTIC_REPOSITORY} forget \
    --keep-daily 7 \
    --keep-weekly 52 \
    --prune

# Run integrity check after backup (quick check, runs in seconds)
echo "Running backup integrity check..."
if restic -r \${RESTIC_REPOSITORY} check --read-data-subset=5%; then
    echo "Backup integrity check passed"
else
    echo "WARNING: Backup integrity check failed!"
    BACKUP_STATUS="failed"
fi

# Send alert based on backup status
if [[ "\${BACKUP_STATUS}" == "failed" ]]; then
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        \${ALERT_SCRIPT} "critical" "Restic backup failed! Check \${LOG_FILE}"
    fi
else
    # Send success notification (dead man's switch pattern)
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        \${ALERT_SCRIPT} "success" "Restic backup completed successfully"
    fi
fi

# Send healthcheck ping
if [[ -f /root/.healthchecks-url ]]; then
    HEALTHCHECK_URL=\$(cat /root/.healthchecks-url)

    # Validate URL format
    if [[ ! "\${HEALTHCHECK_URL}" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]; then
        echo "WARNING: Invalid healthcheck URL format: \${HEALTHCHECK_URL}"
        echo "Expected format: http://example.com/path or https://example.com/path"
        echo "Skipping healthcheck ping"
    else
        if [[ "\${BACKUP_STATUS}" == "success" ]]; then
            if ! curl -fsS -m 10 --retry 5 "\${HEALTHCHECK_URL}" > /dev/null 2>&1; then
                echo "WARNING: Failed to send healthcheck ping to \${HEALTHCHECK_URL}"
            fi
        else
            if ! curl -fsS -m 10 --retry 5 "\${HEALTHCHECK_URL}/fail" > /dev/null 2>&1; then
                echo "WARNING: Failed to send healthcheck ping to \${HEALTHCHECK_URL}/fail"
            fi
        fi
    fi
fi

echo "=== Restic Backup Finished: \$(date) ==="
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
if [[ "\${VERIFY_STATUS}" == "failed" ]]; then
    if [[ -x "\${ALERT_SCRIPT}" ]]; then
        "\${ALERT_SCRIPT}" "critical" "Restic restore verification failed! Manual investigation required."
    fi
    echo "ERROR: Restore verification failed"
    echo "=== Restore Verification Finished: \$(date) ==="
    exit 1
fi

echo "✓ Restore verification successful"
echo "=== Restore Verification Finished: \$(date) ==="
exit 0
EOF

chmod +x ${SCRIPTS_DIR}/verify-restore.sh

# Step 3: Initialize Restic repository
echo ""
echo "=== Step 3: Initializing Restic repository ==="
${SCRIPTS_DIR}/init-restic.sh

# Step 3.5: Validate backup retention policy against available storage
echo ""
echo "=== Validating Backup Retention Policy ==="

# Calculate estimated backup storage requirements
# Retention: 7 daily + 52 weekly backups
DAILY_RETENTION=7
WEEKLY_RETENTION=52
TOTAL_SNAPSHOTS=$((DAILY_RETENTION + WEEKLY_RETENTION))

# Estimate backup size (assume compressed size is 30% of uncompressed)
# Include homes, docker-volumes, and shared/tensorboard
BACKUP_DIRS="${MOUNT_POINT}/homes ${MOUNT_POINT}/docker-volumes ${MOUNT_POINT}/shared/tensorboard"
TOTAL_SIZE_GB=0

for dir in ${BACKUP_DIRS}; do
    if [[ -d "${dir}" ]]; then
        DIR_SIZE_GB=$(du -sb "${dir}" 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
        TOTAL_SIZE_GB=$((TOTAL_SIZE_GB + DIR_SIZE_GB))
    fi
done

echo "Current backup source size: ${TOTAL_SIZE_GB}GB"

# Account for compression (30% of original) and deduplication (save ~20%)
COMPRESSED_SIZE=$(awk "BEGIN {printf \"%.0f\", ${TOTAL_SIZE_GB} * 0.3}")
WITH_DEDUP=$(awk "BEGIN {printf \"%.0f\", ${COMPRESSED_SIZE} * 0.8}")

# Estimate total storage with retention (daily snapshots + weekly)
# Daily snapshots: mostly incremental (assume 10% change per day)
# Weekly snapshots: more significant (assume full backup equivalent)
DAILY_INCREMENTAL=$(awk "BEGIN {printf \"%.0f\", ${WITH_DEDUP} * 0.1 * ${DAILY_RETENTION}}")
WEEKLY_FULL=$(awk "BEGIN {printf \"%.0f\", ${WITH_DEDUP} * ${WEEKLY_RETENTION}}")
ESTIMATED_TOTAL=$((DAILY_INCREMENTAL + WEEKLY_FULL))

echo ""
echo "Backup retention policy:"
echo "  Daily snapshots: ${DAILY_RETENTION} (at 6 AM)"
echo "  Weekly snapshots: ${WEEKLY_RETENTION} (Sunday 3 AM)"
echo ""
echo "Estimated storage requirements:"
echo "  Base backup size: ${WITH_DEDUP}GB (compressed + deduplicated)"
echo "  Daily incrementals: ${DAILY_INCREMENTAL}GB (${DAILY_RETENTION} days)"
echo "  Weekly fulls: ${WEEKLY_FULL}GB (${WEEKLY_RETENTION} weeks)"
echo "  Total estimated: ${ESTIMATED_TOTAL}GB"
echo ""

# Warn if retention might be excessive
MOUNT_SIZE_GB=$(df -BG "${MOUNT_POINT}" | tail -1 | awk '{print $2}' | sed 's/G//')
RETENTION_PERCENT=$(awk "BEGIN {printf \"%.0f\", ${ESTIMATED_TOTAL} * 100.0 / ${MOUNT_SIZE_GB}}")

if [[ ${RETENTION_PERCENT} -gt 50 ]]; then
    echo "⚠️  WARNING: Backup retention may consume ${RETENTION_PERCENT}% of local storage!"
    echo "   Consider:"
    echo "   - Reducing retention periods"
    echo "   - Using remote-only backups (S3, Google Drive)"
    echo "   - Increasing storage capacity"
    echo ""
fi

echo "✓ Backup retention validation complete"
echo ""

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
echo "IMPORTANT: Restic password is stored in /root/.restic-password"
echo "Store this securely - it's required to restore backups!"
echo "To view: cat /root/.restic-password"
echo "=========================================="
echo ""
echo "Manual commands:"
echo "  Create snapshot: ${SCRIPTS_DIR}/create-snapshot.sh daily"
echo "  Run backup: ${SCRIPTS_DIR}/restic-backup.sh"
echo "  List snapshots: restic -r rclone:${BACKUP_REMOTE} snapshots"
echo "  Verify restore: ${SCRIPTS_DIR}/verify-restore.sh"
echo ""
