#!/bin/bash
set -euo pipefail

# ML Training Server - Google Drive Shared Drive Setup
# Mounts Google Workspace Shared Drive with local cache for /shared

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

# Load configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example and edit it."
    exit 1
fi

source "${CONFIG_FILE}"

echo "=== Google Drive Shared Drive Setup ==="
echo ""
echo "This script will:"
echo "  1. Install rclone (if not present)"
echo "  2. Configure Google Workspace Shared Drive access"
echo "  3. Create local cache directory"
echo "  4. Mount Shared Drive to ${MOUNT_POINT}/shared with VFS cache"
echo "  5. Configure systemd service for automatic mounting"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Step 1: Install rclone
echo "=== Step 1: Installing rclone ==="
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | bash
else
    echo "rclone already installed: $(rclone version | head -n1)"
fi

# Step 2: Configure Google Drive Shared Drive
echo ""
echo "=== Step 2: Configuring Google Drive Shared Drive ==="
echo ""

# Check if remote already exists
if rclone listremotes | grep -q "^${GDRIVE_SHARED_REMOTE}:$"; then
    echo "Remote '${GDRIVE_SHARED_REMOTE}' already configured"
    read -p "Reconfigure? (y/n): " reconfigure
    if [[ "$reconfigure" == "y" ]]; then
        rclone config delete "${GDRIVE_SHARED_REMOTE}" || true
    else
        echo "Using existing configuration"
    fi
fi

if ! rclone listremotes | grep -q "^${GDRIVE_SHARED_REMOTE}:$"; then
    echo ""
    echo "Configure Google Drive Shared Drive access:"
    echo "  1. Choose 'n' for new remote"
    echo "  2. Name: ${GDRIVE_SHARED_REMOTE}"
    echo "  3. Storage: 'drive' (Google Drive)"
    echo "  4. Client ID/Secret: Leave blank or use your own"
    echo "  5. Scope: 'drive' (full access)"
    echo "  6. Service Account File: Leave blank unless using service account"
    echo "  7. Advanced config: 'n'"
    echo "  8. Auto config: 'y' (opens browser for OAuth)"
    echo "  9. Configure for Shared Drive: 'y'"
    echo " 10. Select your Shared Drive from the list"
    echo ""
    read -p "Press Enter to continue..."

    rclone config

    # Verify remote was created
    if ! rclone listremotes | grep -q "^${GDRIVE_SHARED_REMOTE}:$"; then
        echo "ERROR: Remote '${GDRIVE_SHARED_REMOTE}' not found!"
        echo "Please run 'rclone config' manually and create the remote."
        exit 1
    fi
fi

# Test access
echo ""
echo "Testing Shared Drive access..."
if rclone lsd "${GDRIVE_SHARED_REMOTE}:" --max-depth 1 2>/dev/null; then
    echo "✅ Shared Drive access verified"
else
    echo "❌ ERROR: Cannot access Shared Drive!"
    echo "Please verify OAuth permissions and Shared Drive access."
    exit 1
fi

# Step 3: Calculate storage allocation and validate
echo ""
echo "=== Step 3: Storage Allocation Calculation ==="

# Get total BTRFS size in GB
TOTAL_BTRFS_GB=$(df -BG "${MOUNT_POINT}" | tail -n1 | awk '{print $2}' | sed 's/G//')

# Calculate total user data space needed
USER_COUNT=$(echo ${USERS} | wc -w)
TOTAL_USER_DATA_GB=$((USER_COUNT * USER_QUOTA_GB))

# Auto-calculate snapshot overhead (50% of user data)
SNAPSHOT_OVERHEAD_GB=$(awk "BEGIN {printf \"%.0f\", ${TOTAL_USER_DATA_GB} * 0.5}")

# Total reserved space for user data and snapshots
RESERVED_GB=$((TOTAL_USER_DATA_GB + SNAPSHOT_OVERHEAD_GB))

# Calculate safe limit with safety margin
SAFE_LIMIT_GB=$(awk "BEGIN {printf \"%.0f\", ${TOTAL_BTRFS_GB} * (1 - ${STORAGE_SAFETY_MARGIN_PERCENT}/100.0)}")

echo "Storage breakdown:"
echo "  Total BTRFS storage: ${TOTAL_BTRFS_GB}GB"
echo "  Number of users: ${USER_COUNT}"
echo "  Per-user quota: ${USER_QUOTA_GB}GB (home + workspace + docker-volumes combined)"
echo "  Total user data: ${TOTAL_USER_DATA_GB}GB"
echo "  Snapshot overhead: ${SNAPSHOT_OVERHEAD_GB}GB (0.5× user data)"
echo "  Total reserved: ${RESERVED_GB}GB"
echo "  Safe limit (${STORAGE_SAFETY_MARGIN_PERCENT}% margin): ${SAFE_LIMIT_GB}GB"
echo ""

# Validate: Reserved space must fit within safe limit
if [[ ${RESERVED_GB} -gt ${SAFE_LIMIT_GB} ]]; then
    echo "❌ ERROR: Insufficient storage for current configuration!"
    echo ""
    echo "Required space: ${RESERVED_GB}GB (user data + snapshots)"
    echo "Available space: ${SAFE_LIMIT_GB}GB (with ${STORAGE_SAFETY_MARGIN_PERCENT}% safety margin)"
    echo "Shortfall: $((RESERVED_GB - SAFE_LIMIT_GB))GB"
    echo ""
    echo "Solutions:"
    echo "  1. Reduce number of users in config.sh (currently ${USER_COUNT})"
    echo "  2. Reduce USER_QUOTA_GB in config.sh (currently ${USER_QUOTA_GB}GB per user)"
    echo "  3. Add more physical storage"
    echo ""
    exit 1
fi

echo "✅ Storage validation passed!"
echo ""

# Calculate VFS cache size (80% of free space after reservations)
FREE_GB=$((TOTAL_BTRFS_GB - RESERVED_GB))
CACHE_SIZE_GB=$(awk "BEGIN {printf \"%.0f\", ${FREE_GB} * (1 - ${STORAGE_SAFETY_MARGIN_PERCENT}/100.0)}")
SAFETY_BUFFER_GB=$((FREE_GB - CACHE_SIZE_GB))

echo "Google Drive VFS cache allocation:"
echo "  Free space after reservations: ${FREE_GB}GB"
echo "  VFS cache size: ${CACHE_SIZE_GB}GB ($((CACHE_SIZE_GB * 100 / TOTAL_BTRFS_GB))% of total disk)"
echo "  Safety buffer: ${SAFETY_BUFFER_GB}GB (${STORAGE_SAFETY_MARGIN_PERCENT}% of free space)"
echo ""

# Create cache directory
CACHE_DIR="${GDRIVE_CACHE_DIR}"
mkdir -p "${CACHE_DIR}"
echo "Cache directory: ${CACHE_DIR}"

# Step 4: Create systemd service for automatic mounting
echo ""
echo "=== Step 4: Creating systemd mount service ==="

cat > /etc/systemd/system/gdrive-shared.service <<EOF
[Unit]
Description=Google Drive Shared Drive mount for /shared
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
# Mount Shared Drive with aggressive VFS caching for local-like performance
ExecStart=/usr/bin/rclone mount ${GDRIVE_SHARED_REMOTE}: ${MOUNT_POINT}/shared \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size ${CACHE_SIZE_GB}G \\
    --vfs-cache-max-age ${GDRIVE_CACHE_MAX_AGE} \\
    --vfs-read-chunk-size ${GDRIVE_READ_CHUNK_SIZE} \\
    --vfs-read-chunk-size-limit ${GDRIVE_READ_CHUNK_LIMIT} \\
    --vfs-write-back ${GDRIVE_WRITE_BACK} \\
    --buffer-size ${GDRIVE_BUFFER_SIZE} \\
    --dir-cache-time ${GDRIVE_DIR_CACHE_TIME} \\
    --poll-interval ${GDRIVE_POLL_INTERVAL} \\
    --cache-dir ${CACHE_DIR} \\
    --allow-other \\
    --allow-non-empty \\
    --default-permissions \\
    --uid 0 \\
    --gid 0 \\
    --umask 022 \\
    --transfers ${GDRIVE_TRANSFERS} \\
    --checkers ${GDRIVE_CHECKERS} \\
    --drive-chunk-size ${GDRIVE_CHUNK_SIZE} \\
    --drive-upload-cutoff ${GDRIVE_UPLOAD_CUTOFF} \\
    --drive-acknowledge-abuse \\
    --fast-list \\
    --no-modtime \\
    --log-level ${GDRIVE_LOG_LEVEL} \\
    --log-file /var/log/gdrive-shared.log \\
    --syslog

# Restart on failure
Restart=on-failure
RestartSec=10s

# Health monitoring
ExecStartPost=/bin/sleep 5
ExecStartPost=/bin/bash -c 'ls ${MOUNT_POINT}/shared > /dev/null'

[Install]
WantedBy=multi-user.target
EOF

# Step 5: Create monitoring script
echo ""
echo "=== Step 5: Creating monitoring script ==="

mkdir -p /opt/scripts/monitoring

cat > /opt/scripts/monitoring/check-gdrive-mount.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Check if Google Drive Shared Drive is mounted and healthy

MOUNT_POINT="${MOUNT_POINT:-/mnt/storage}"
SHARED_DIR="${MOUNT_POINT}/shared"
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Check if mounted
if ! mountpoint -q "${SHARED_DIR}"; then
    echo "ERROR: ${SHARED_DIR} is not mounted!"

    # Send alert
    if [[ -x "${ALERT_SCRIPT}" ]]; then
        ${ALERT_SCRIPT} "critical" "Google Drive Shared Drive is not mounted at ${SHARED_DIR}! Attempting to restart service..."
    fi

    # Attempt to restart
    systemctl restart gdrive-shared.service
    sleep 10

    # Check again
    if ! mountpoint -q "${SHARED_DIR}"; then
        if [[ -x "${ALERT_SCRIPT}" ]]; then
            ${ALERT_SCRIPT} "critical" "Failed to remount Google Drive Shared Drive at ${SHARED_DIR}!"
        fi
        exit 1
    else
        if [[ -x "${ALERT_SCRIPT}" ]]; then
            ${ALERT_SCRIPT} "info" "Google Drive Shared Drive successfully remounted at ${SHARED_DIR}"
        fi
    fi
fi

# Check if readable (ls should succeed)
if ! timeout 30 ls "${SHARED_DIR}" > /dev/null 2>&1; then
    echo "ERROR: ${SHARED_DIR} is mounted but not readable!"

    if [[ -x "${ALERT_SCRIPT}" ]]; then
        ${ALERT_SCRIPT} "warning" "Google Drive Shared Drive mount is unresponsive. Restarting..."
    fi

    systemctl restart gdrive-shared.service
    exit 1
fi

echo "✅ Google Drive Shared Drive is healthy"
exit 0
EOF

chmod +x /opt/scripts/monitoring/check-gdrive-mount.sh

# Create cron job for health check
cat > /etc/cron.d/gdrive-mount-check <<EOF
# Check Google Drive mount every 5 minutes
*/5 * * * * root /opt/scripts/monitoring/check-gdrive-mount.sh >> /var/log/gdrive-mount-check.log 2>&1
EOF

# Step 6: Create cache cleanup script
echo ""
echo "=== Step 6: Creating cache management script ==="

cat > /opt/scripts/monitoring/gdrive-cache-stats.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Display Google Drive cache statistics

CACHE_DIR="${GDRIVE_CACHE_DIR:-/mnt/storage/cache/gdrive}"

echo "=== Google Drive Cache Statistics ==="
echo ""

# Cache directory size
if [[ -d "${CACHE_DIR}" ]]; then
    echo "Cache directory: ${CACHE_DIR}"
    CACHE_SIZE=$(du -sh "${CACHE_DIR}" | awk '{print $1}')
    echo "Current size: ${CACHE_SIZE}"

    # File count
    FILE_COUNT=$(find "${CACHE_DIR}" -type f 2>/dev/null | wc -l)
    echo "Cached files: ${FILE_COUNT}"

    # Disk usage
    echo ""
    df -h "${CACHE_DIR}" | tail -n1
else
    echo "Cache directory not found: ${CACHE_DIR}"
fi

echo ""
echo "=== rclone VFS Cache Info ==="
rclone rc vfs/stats 2>/dev/null || echo "rclone RC interface not enabled"
EOF

chmod +x /opt/scripts/monitoring/gdrive-cache-stats.sh

# Step 7: Enable fuse module
echo ""
echo "=== Step 7: Enabling FUSE ==="

if ! lsmod | grep -q fuse; then
    modprobe fuse
fi

if ! grep -q "^fuse$" /etc/modules 2>/dev/null; then
    echo "fuse" >> /etc/modules
fi

# Step 8: Configure /etc/fstab (for reference only, systemd manages mount)
echo ""
echo "=== Step 8: Adding entry to /etc/fstab (for reference) ==="

FSTAB_ENTRY="# Google Drive Shared Drive (managed by systemd gdrive-shared.service)"

if ! grep -q "gdrive-shared" /etc/fstab; then
    echo "" >> /etc/fstab
    echo "${FSTAB_ENTRY}" >> /etc/fstab
    echo "# ${GDRIVE_SHARED_REMOTE}: ${MOUNT_POINT}/shared rclone rw,noauto,nofail,_netdev,x-systemd.automount 0 0" >> /etc/fstab
fi

# Step 9: Start service
echo ""
echo "=== Step 9: Starting Google Drive Shared Drive mount ==="

# Ensure mount point exists
mkdir -p "${MOUNT_POINT}/shared"

# Reload systemd
systemctl daemon-reload

# Enable and start service
systemctl enable gdrive-shared.service
systemctl start gdrive-shared.service

# Wait for mount
echo "Waiting for mount to complete..."
for i in {1..30}; do
    if mountpoint -q "${MOUNT_POINT}/shared"; then
        echo "✅ Mount successful!"
        break
    fi
    echo -n "."
    sleep 1
done

if ! mountpoint -q "${MOUNT_POINT}/shared"; then
    echo ""
    echo "❌ ERROR: Mount failed!"
    echo "Check logs: journalctl -u gdrive-shared.service -n 50"
    echo "Or: tail -f /var/log/gdrive-shared.log"
    exit 1
fi

# Test read access
echo ""
echo "Testing read access..."
if timeout 30 ls "${MOUNT_POINT}/shared" > /dev/null; then
    echo "✅ Read access verified"
else
    echo "⚠️  WARNING: Mount succeeded but ls timed out"
    echo "This may be normal for large directories on first access"
fi

# Display cache stats
echo ""
/opt/scripts/monitoring/gdrive-cache-stats.sh

# Step 10: Create user guide
echo ""
echo "=== Step 10: Creating user guide ==="

cat > /root/GDRIVE-SHARED-GUIDE.md <<'EOF'
# Google Drive Shared Drive Guide

## Overview

The `/shared` directory is now mounted from a Google Workspace Shared Drive with massive local caching for near-local performance.

## Architecture

```
Google Workspace Shared Drive (cloud)
         ↓
    rclone mount with VFS cache
         ↓
/mnt/storage/shared (accessible in containers as /shared)
         ↓
Local cache: /mnt/storage/cache/gdrive
```

## Features

- **Full VFS Cache Mode**: Files are downloaded on first access and cached locally
- **Write-back**: Local writes are batched and uploaded in background
- **Auto-recovery**: Systemd service restarts on failure
- **Health monitoring**: Cron job checks mount every 5 minutes

## Performance Characteristics

- **First access**: Downloads from Google Drive (~10-100 MB/s depending on connection)
- **Subsequent access**: Near-local speed (reads from cache)
- **Writes**: Immediate local write, async upload to Google Drive
- **Cache expiry**: Files removed from cache after ${GDRIVE_CACHE_MAX_AGE} of no access

## User Access

Users access the Shared Drive as `/shared` (read-write) in their containers:
- `/shared` - Read-write access to all Shared Drive files for team collaboration
- `/shared/tensorboard/${USERNAME}` - Personal TensorBoard logs directory

## Management Commands

### Check mount status
```bash
systemctl status gdrive-shared.service
mountpoint /mnt/storage/shared
```

### View mount logs
```bash
journalctl -u gdrive-shared.service -f
tail -f /var/log/gdrive-shared.log
```

### Cache statistics
```bash
/opt/scripts/monitoring/gdrive-cache-stats.sh
```

### Manual health check
```bash
/opt/scripts/monitoring/check-gdrive-mount.sh
```

### Restart mount
```bash
systemctl restart gdrive-shared.service
```

### Clear cache (frees disk space)
```bash
# Stop service first
systemctl stop gdrive-shared.service

# Clear cache
rm -rf ${GDRIVE_CACHE_DIR}/*

# Restart service
systemctl start gdrive-shared.service
```

## Troubleshooting

### Mount shows as hung/unresponsive
```bash
# Force unmount and restart
systemctl stop gdrive-shared.service
fusermount -uz /mnt/storage/shared || umount -l /mnt/storage/shared
systemctl start gdrive-shared.service
```

### "Transport endpoint is not connected" error
```bash
# This means rclone crashed, just restart
systemctl restart gdrive-shared.service
```

### Slow first access to large directories
This is normal - rclone needs to fetch the directory listing from Google Drive. Subsequent access will be cached.

### Check OAuth token validity
```bash
rclone lsd ${GDRIVE_SHARED_REMOTE}: --max-depth 1
```

If this fails, reconfigure:
```bash
rclone config reconnect ${GDRIVE_SHARED_REMOTE}:
```

## Cache Management

The cache is automatically managed by rclone:
- **Max size**: ${CACHE_SIZE_GB}GB (${GDRIVE_CACHE_PERCENT}% of storage)
- **Max age**: ${GDRIVE_CACHE_MAX_AGE}
- **Eviction**: LRU (least recently used)

Monitor cache usage:
```bash
du -sh ${GDRIVE_CACHE_DIR}
df -h /mnt/storage
```

## Best Practices

1. **Pre-populate cache**: If possible, access frequently-used files once to cache them
2. **Large datasets**: Consider keeping on local `/workspace` if accessed frequently
3. **Shared datasets**: Perfect use case for Shared Drive (everyone can access)
4. **Monitor cache size**: Ensure cache doesn't fill up the disk

## Integration with Containers

Containers see the mount at `/shared` (read-only) and `/shared/tensorboard/${USERNAME}` (read-write).

The mount happens on the host, and Docker bind-mounts it into containers:
- Host: `/mnt/storage/shared`
- Container: `/shared`

No special configuration needed in containers.
EOF

echo "User guide created: /root/GDRIVE-SHARED-GUIDE.md"

# Final summary
echo ""
echo "=== Google Drive Shared Drive Setup Complete ==="
echo ""
echo "✅ Shared Drive mounted: ${MOUNT_POINT}/shared"
echo "✅ Cache directory: ${CACHE_DIR}"
echo "✅ Cache size: ${CACHE_SIZE_GB}GB"
echo "✅ Systemd service: gdrive-shared.service"
echo "✅ Health monitoring: Every 5 minutes"
echo ""
echo "Service status:"
systemctl status gdrive-shared.service --no-pager | head -n 10
echo ""
echo "Management commands:"
echo "  - Status: systemctl status gdrive-shared.service"
echo "  - Logs: journalctl -u gdrive-shared.service -f"
echo "  - Cache stats: /opt/scripts/monitoring/gdrive-cache-stats.sh"
echo "  - Health check: /opt/scripts/monitoring/check-gdrive-mount.sh"
echo ""
echo "User guide: /root/GDRIVE-SHARED-GUIDE.md"
echo ""
echo "⚠️  Note: First access to files will download from Google Drive"
echo "          Subsequent access will be near-local speed (from cache)"
echo ""
