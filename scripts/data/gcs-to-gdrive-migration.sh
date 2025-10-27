#!/bin/bash
set -euo pipefail

# GCS to GDrive Migration Script
# Run this on a temporary GCE instance in the same region as your GCS bucket
# to avoid egress charges

echo "=== GCS to GDrive Migration ==="

# Try to load configuration from config.sh if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config.sh"

if [[ -f "${CONFIG_FILE}" ]]; then
    echo "Loading configuration from ${CONFIG_FILE}..."
    source "${CONFIG_FILE}"
    # Use config variables with defaults
    GCS_BUCKET="${GCS_BUCKET:-gs://your-bucket-name}"
    GDRIVE_REMOTE="${GDRIVE_DEST:-gdrive:backups/gcs-migration}"
else
    echo "Config file not found, using defaults (you can override with parameters)"
    # Default configuration - can be overridden by parameters
    GCS_BUCKET="${1:-gs://your-bucket-name}"
    GDRIVE_REMOTE="${2:-gdrive:backups/gcs-migration}"
fi

BANDWIDTH_LIMIT="${3:-100M}"  # 100 Mbps
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
LOG_FILE="/var/log/gcs-gdrive-migration.log"

# Show usage if bucket is not set
if [[ "${GCS_BUCKET}" == "gs://your-bucket-name" ]]; then
    echo ""
    echo "Usage: $0 [GCS_BUCKET] [GDRIVE_REMOTE] [BANDWIDTH_LIMIT]"
    echo "Example: $0 gs://my-bucket gdrive:my-folder 100M"
    echo ""
    echo "Or set GCS_BUCKET and GDRIVE_DEST in config.sh"
    exit 1
fi

# Redirect output to log file
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "Migration started: $(date)"
echo "Source: ${GCS_BUCKET}"
echo "Destination: ${GDRIVE_REMOTE}"
echo "Bandwidth limit: ${BANDWIDTH_LIMIT}"
echo ""

# Check rclone is installed
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | sudo bash
fi

# Check if rclone is configured
if ! rclone listremotes | grep -q "gdrive"; then
    echo "ERROR: rclone not configured for Google Drive"
    echo "Run: rclone config"
    exit 1
fi

# Function to send progress updates
send_progress_update() {
    local message="$1"
    echo "${message}"
    if [[ -x "${ALERT_SCRIPT}" ]]; then
        ${ALERT_SCRIPT} "info" "${message}"
    fi
}

# Start migration
send_progress_update "Starting 50TB GCS to GDrive migration..."

# Use rclone sync with options:
# --progress: Show progress
# --stats: Show stats every minute
# --bwlimit: Limit bandwidth to 100 Mbps
# --transfers: Number of parallel transfers
# --checkers: Number of parallel checkers
# --log-file: Log to file
# --checksum: Verify with checksums (slower but safer)

rclone sync \
    "${GCS_BUCKET}/" \
    "${GDRIVE_REMOTE}/" \
    --progress \
    --stats 1h \
    --bwlimit ${BANDWIDTH_LIMIT} \
    --transfers 8 \
    --checkers 16 \
    --log-level INFO \
    --use-server-modtime \
    --fast-list \
    --drive-chunk-size 128M \
    --drive-upload-cutoff 128M

# Check exit status
if [[ $? -eq 0 ]]; then
    send_progress_update "Migration completed successfully!"

    # Verify data
    echo "Verifying data integrity..."
    rclone check "${GCS_BUCKET}/" "${GDRIVE_REMOTE}/" --one-way

    if [[ $? -eq 0 ]]; then
        send_progress_update "Data verification successful!"
    else
        send_progress_update "WARNING: Data verification found differences!"
    fi
else
    send_progress_update "ERROR: Migration failed! Check ${LOG_FILE}"
    exit 1
fi

echo "Migration completed: $(date)"

# Display summary
echo ""
echo "=== Migration Summary ==="
rclone size "${GDRIVE_REMOTE}/"
echo ""
echo "Check log file: ${LOG_FILE}"
echo ""
echo "Next steps:"
echo "  1. Verify data in GDrive"
echo "  2. Set up daily sync on on-premise server"
echo "  3. Keep GCS as backup for now"
echo ""
