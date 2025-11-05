#!/bin/bash
set -euo pipefail

# ML Training Server - Data Pipeline Setup
# Configures daily customer data sync from GCS to GDrive

echo "=== Data Pipeline Setup ==="

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

SCRIPTS_DIR="/opt/scripts/data"

# Load common functions
COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
    source "${COMMON_LIB}"
fi

# Use config variables with defaults
GCS_BUCKET="${GCS_BUCKET:-gcs:customer-daily-bucket}"
GDRIVE_CUSTOMER_DATA="${GDRIVE_CUSTOMER_DATA:-gdrive:customer-daily}"

# Install rclone if not already installed
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | bash
fi

# Check network connectivity (required for GCS and GDrive access)
echo ""
if ! check_network 3; then
    echo "ERROR: This script requires internet connectivity to:"
    echo "  - Access Google Cloud Storage (GCS)"
    echo "  - Access Google Drive"
    echo "  - Configure data sync pipeline"
    exit 1
fi

# Step 1: Configure rclone
echo ""
echo "=== Step 1: Configuring rclone ==="

echo "You need to configure two rclone remotes:"
echo "  1. 'gcs' - Google Cloud Storage"
echo "  2. 'gdrive' - Google Drive"
echo ""

while true; do
    read -p "Have you already configured rclone? (y/n): " rclone_configured
    if [[ "${rclone_configured}" =~ ^[yn]$ ]]; then
        break
    fi
    echo "ERROR: Invalid input. Please enter 'y' or 'n'"
done

if [[ "$rclone_configured" != "y" ]]; then
    echo ""
    echo "Configure rclone now:"
    echo "  rclone config"
    echo ""
    echo "Create two remotes:"
    echo "  - gcs (Google Cloud Storage)"
    echo "  - gdrive (Google Drive)"
    echo ""
    rclone config
fi

# Verify remotes exist
# First check if rclone command works
if ! rclone listremotes &>/dev/null; then
    echo "ERROR: rclone command failed - check installation"
    exit 1
fi

# Check for gcs remote (remote names end with colon, e.g., "gcs:")
if ! rclone listremotes | grep -q "^gcs:$"; then
    echo "ERROR: 'gcs' remote not configured"
    exit 1
fi

# Check for gdrive remote
if ! rclone listremotes | grep -q "^gdrive:$"; then
    echo "ERROR: 'gdrive' remote not configured"
    exit 1
fi

echo "rclone remotes configured"

# Step 2: Create data sync scripts
echo ""
echo "=== Step 2: Creating data sync scripts ==="

mkdir -p ${SCRIPTS_DIR}

# Daily customer data sync script (use config values)
cat > ${SCRIPTS_DIR}/sync-customer-data.sh <<EOF
#!/bin/bash
set -euo pipefail

# Daily customer data sync from GCS to GDrive
GCS_BUCKET="${GCS_BUCKET}"
GDRIVE_DEST="${GDRIVE_CUSTOMER_DATA}"
BANDWIDTH_LIMIT="${DATA_SYNC_BANDWIDTH_LIMIT_MBPS}M"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
LOG_FILE="/var/log/customer-data-sync.log"

# Redirect output to log
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "=== Customer Data Sync: $(date) ==="

# Sync data from GCS to GDrive
RCLONE_OUTPUT=$(rclone copy \
    "${GCS_BUCKET}/" \
    "${GDRIVE_DEST}/" \
    --bwlimit ${BANDWIDTH_LIMIT} \
    --transfers 4 \
    --checkers 8 \
    --retries 3 \
    --log-level INFO \
    --use-server-modtime \
    --fast-list 2>&1)
RCLONE_EXIT=$?

if [[ ${RCLONE_EXIT} -eq 0 ]]; then
    echo "Sync completed successfully"
    SYNC_STATUS="success"

    # Get sync summary
    SUMMARY=$(rclone size "${GDRIVE_DEST}/")
    echo "${SUMMARY}"
else
    echo "ERROR: Sync failed with exit code ${RCLONE_EXIT}"
    echo "Error output: ${RCLONE_OUTPUT}"
    case ${RCLONE_EXIT} in
        3) echo "Cause: Temporary error (retry may succeed)" ;;
        4) echo "Cause: Authentication failure" ;;
        5) echo "Cause: Not found" ;;
        6) echo "Cause: Insufficient permissions" ;;
        *) echo "Cause: Unknown (check rclone documentation)" ;;
    esac
    SYNC_STATUS="failed"
fi

# Send alert if failed
if [[ "${SYNC_STATUS}" == "failed" ]] && [[ -x "${ALERT_SCRIPT}" ]]; then
    ${ALERT_SCRIPT} "critical" "Customer data sync failed! Check ${LOG_FILE}"
fi

# Send healthcheck ping
if [[ -f /root/.healthchecks-data-sync-url ]]; then
    HEALTHCHECK_URL=$(cat /root/.healthchecks-data-sync-url)

    # Validate URL format
    if [[ ! "${HEALTHCHECK_URL}" =~ ^https?:// ]]; then
        echo "WARNING: Invalid healthcheck URL format: ${HEALTHCHECK_URL}"
        echo "Skipping healthcheck ping"
    else
        if [[ "${SYNC_STATUS}" == "success" ]]; then
            if ! curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}" > /dev/null 2>&1; then
                echo "WARNING: Failed to send healthcheck ping to ${HEALTHCHECK_URL}"
            fi
        else
            if ! curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}/fail" > /dev/null 2>&1; then
                echo "WARNING: Failed to send healthcheck ping to ${HEALTHCHECK_URL}/fail"
            fi
        fi
    fi
fi

echo "=== Sync Finished: $(date) ==="
echo ""
EOF

chmod +x ${SCRIPTS_DIR}/sync-customer-data.sh

# Manual sync script (for testing)
cat > ${SCRIPTS_DIR}/manual-sync.sh <<EOF
#!/bin/bash
set -euo pipefail

# Manual data sync (no bandwidth limit, for testing)
GCS_BUCKET="${GCS_BUCKET}"
GDRIVE_DEST="${GDRIVE_CUSTOMER_DATA}"

echo "=== Manual Customer Data Sync ==="
echo "Source: ${GCS_BUCKET}"
echo "Destination: ${GDRIVE_DEST}"
echo ""

rclone copy \
    "${GCS_BUCKET}/" \
    "${GDRIVE_DEST}/" \
    --progress \
    --stats 30s \
    --transfers 8 \
    --checkers 16 \
    --log-level INFO

echo ""
echo "Sync completed"
EOF

chmod +x ${SCRIPTS_DIR}/manual-sync.sh

# GDrive cleanup script (for old data)
cat > ${SCRIPTS_DIR}/cleanup-old-data.sh <<EOF
#!/bin/bash
set -euo pipefail

# Cleanup old customer data from GDrive
GDRIVE_PATH="${GDRIVE_CUSTOMER_DATA}"
DAYS_TO_KEEP=${DATA_CLEANUP_DAYS}

echo "=== Cleanup Old Data ==="
echo "Path: ${GDRIVE_PATH}"
echo "Keeping files newer than ${DAYS_TO_KEEP} days"
echo ""

# Delete files older than X days
rclone delete \
    "${GDRIVE_PATH}/" \
    --min-age ${DAYS_TO_KEEP}d \
    --verbose

echo "Cleanup completed"
EOF

chmod +x ${SCRIPTS_DIR}/cleanup-old-data.sh

# Step 3: Configure cron job
echo ""
echo "=== Step 3: Configuring cron job ==="

cat > /etc/cron.d/customer-data-sync <<EOF
# Daily customer data sync from GCS to GDrive (4 AM)
0 4 * * * root ${SCRIPTS_DIR}/sync-customer-data.sh
EOF

echo "Cron job configured: Daily at 4 AM"

# Step 4: Setup systemd service (alternative to cron)
echo ""
read -p "Also create systemd service/timer? (y/n): " setup_systemd

if [[ "$setup_systemd" == "y" ]]; then
    # Create service
    cat > /etc/systemd/system/customer-data-sync.service <<EOF
[Unit]
Description=Customer Data Sync (GCS to GDrive)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPTS_DIR}/sync-customer-data.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=customer-data-sync
EOF

    # Create timer
    cat > /etc/systemd/system/customer-data-sync.timer <<EOF
[Unit]
Description=Customer Data Sync Timer
Requires=customer-data-sync.service

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable customer-data-sync.timer
    systemctl start customer-data-sync.timer

    echo "Systemd timer enabled"
fi

# Step 5: Setup healthchecks.io (optional)
echo ""
read -p "Set up healthchecks.io for data sync monitoring? (y/n): " setup_healthcheck

if [[ "$setup_healthcheck" == "y" ]]; then
    echo "Create a check at https://healthchecks.io/"
    echo "Then paste the ping URL here:"
    read -p "Ping URL: " healthcheck_url
    echo "${healthcheck_url}" > /root/.healthchecks-data-sync-url
    chmod 600 /root/.healthchecks-data-sync-url
    echo "healthchecks.io configured"
fi

# Step 6: Test sync
echo ""
read -p "Run test sync now? (y/n): " run_test

if [[ "$run_test" == "y" ]]; then
    echo "Running test sync..."
    ${SCRIPTS_DIR}/sync-customer-data.sh
fi

echo ""
echo "=== Data Pipeline Setup Complete ==="
echo ""
echo "Scripts installed:"
echo "  - Daily sync: ${SCRIPTS_DIR}/sync-customer-data.sh"
echo "  - Manual sync: ${SCRIPTS_DIR}/manual-sync.sh"
echo "  - Cleanup: ${SCRIPTS_DIR}/cleanup-old-data.sh"
echo ""
echo "Schedule:"
echo "  - Daily sync: 4 AM (100 Mbps limit)"
echo ""
echo "Log file: /var/log/customer-data-sync.log"
echo ""
echo "Migration timeline:"
echo "  Month 1-2: Migrate 50TB GCS → GDrive"
echo "  Month 3-6: Daily sync GCS → GDrive (customer uploads to GCS)"
echo "  Month 6-11: Customer uploads to GDrive (keep GCS backup)"
echo "  Month 12+: GCS only for serving data"
echo ""
