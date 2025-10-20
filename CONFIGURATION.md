##Configuration Guide

This project is now **fully customizable** via a central configuration file. You can adjust users, storage devices, RAID levels, and many other parameters without editing any scripts.

## Quick Start

1. **Copy the configuration template:**
   ```bash
   cp config.sh.example config.sh
   ```

2. **Edit your configuration:**
   ```bash
   nano config.sh
   ```

3. **Validate your configuration:**
   ```bash
   ./scripts/00-validate-config.sh
   ```

4. **Run setup scripts** as normal - they will read from `config.sh`

## Key Customizations

### Users

**Change the number and names of users:**

```bash
# In config.sh
USERS="john jane mike"  # 3 users instead of 5
```

All scripts automatically adapt to your user list:
- User accounts created with sequential UIDs
- Docker services generated per user
- Monitoring quota checks for each user
- Cloudflare Tunnel routes for each user

### Storage Devices

**Auto-Detection (Recommended):**
```bash
# Leave empty for auto-detection
NVME_DEVICE=""
HDD_DEVICES=""
```

The system will automatically detect:
- NVMe/SSD devices (prefers NVMe, falls back to /dev/sda if SSD)
- All rotational HDDs (skips SSDs)

**Manual Specification:**
```bash
# Specify exact devices
NVME_DEVICE="/dev/nvme0n1"
HDD_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf"
```

### SSD/NVMe Size

**Flexible OS partition:**
```bash
# Reserve 50GB for OS instead of 100GB
OS_PARTITION_SIZE_GB=50

# Reserve 200GB for OS (large system partition)
OS_PARTITION_SIZE_GB=200
```

The remaining space is automatically used for bcache.

### HDD Configuration

**Different RAID levels based on disk count:**

```bash
# 2 disks - use RAID1 (mirroring)
BTRFS_RAID_LEVEL="raid1"

# 3 disks - still use RAID1 (one disk as spare)
BTRFS_RAID_LEVEL="raid1"

# 4+ disks - use RAID10 (best performance + redundancy)
BTRFS_RAID_LEVEL="raid10"

# Fast but NO redundancy (not recommended)
BTRFS_RAID_LEVEL="raid0"

# Single disk (no redundancy)
BTRFS_RAID_LEVEL="single"
```

**Different HDD sizes:**
The system works with any HDD size. The total usable capacity depends on RAID level:
- RAID10: ~50% of total (e.g., 4x10TB = 20TB usable)
- RAID1: ~50% of total (e.g., 2x8TB = 8TB usable)
- RAID0: ~100% of total (e.g., 3x12TB = 36TB usable, NO redundancy!)
- Single: 100% of disk size

### Bcache

**Disable bcache** if you don't have an SSD/NVMe:
```bash
BCACHE_MODE="none"
```

**Change bcache mode:**
```bash
# Best performance, requires UPS
BCACHE_MODE="writeback"

# Safer, slightly slower
BCACHE_MODE="writethrough"

# Write-around (rarely used)
BCACHE_MODE="writearound"
```

### Compression

```bash
# Light compression (less CPU, less space savings)
BTRFS_COMPRESSION="zstd:1"

# Default (balanced)
BTRFS_COMPRESSION="zstd:3"

# Maximum compression (more CPU, more space savings)
BTRFS_COMPRESSION="zstd:15"

# Alternative algorithms
BTRFS_COMPRESSION="lzo"    # Fast, less compression
BTRFS_COMPRESSION="zlib"   # Good compression, more CPU
BTRFS_COMPRESSION="none"   # No compression
```

## Configuration Sections

### System Configuration
- `SERVER_HOSTNAME`: Server hostname
- `MOUNT_POINT`: Where BTRFS is mounted (default: `/mnt/storage`)

### User Configuration
- `USERS`: Space-separated list of usernames
- `FIRST_UID`: Starting UID (default: 1000)
- `USER_SHELL`: Default shell (default: `/bin/bash`)
- `USER_GROUPS`: Groups to add users to (default: `docker sudo`)

### Storage Configuration
- `NVME_DEVICE`: SSD/NVMe device (auto-detected if empty)
- `HDD_DEVICES`: Space-separated HDD devices (auto-detected if empty)
- `OS_PARTITION_SIZE_GB`: OS partition size in GB
- `BTRFS_RAID_LEVEL`: RAID level (raid10, raid1, raid0, single)
- `BTRFS_COMPRESSION`: Compression algorithm and level
- `BCACHE_MODE`: Caching mode (writeback, writethrough, writearound, none)

### Resource Limits (Per User)
- `MEMORY_GUARANTEE_GB`: Minimum RAM per user container
- `MEMORY_LIMIT_GB`: Maximum RAM per user container
- `SWAP_SIZE_GB`: Swap size per container
- `USER_QUOTA_TB`: Disk quota soft limit in TB (0 to disable)
- `QUOTA_WARNING_DAYS`: Days before quota warning escalates

### Docker Configuration
- `DOCKER_STORAGE_DRIVER`: Storage driver (btrfs, overlay2, zfs)
- `DOCKER_LOG_MAX_SIZE`: Max size per log file
- `DOCKER_LOG_MAX_FILES`: Number of log files to keep

### Networking
- `DOMAIN`: Your domain for Cloudflare Tunnel (e.g., "example.com")
- `CODE_SERVER_PREFIX`: Subdomain prefix for code-server (default: "code")
- `JUPYTER_PREFIX`: Subdomain prefix for Jupyter (default: "jupyter")
- `LOCAL_NETWORK_CIDR`: Local network CIDR for firewall (optional)

### Backup Configuration
- `BACKUP_REMOTE`: rclone remote for backups
- `BACKUP_BANDWIDTH_LIMIT_MBPS`: Upload bandwidth limit
- `SNAPSHOT_HOURLY_KEEP`: Number of hourly snapshots to keep
- `SNAPSHOT_DAILY_KEEP`: Number of daily snapshots to keep
- `SNAPSHOT_WEEKLY_KEEP`: Number of weekly snapshots to keep
- `RESTIC_KEEP_DAILY`: Restic daily retention
- `RESTIC_KEEP_WEEKLY`: Restic weekly retention
- `BACKUP_HOUR`: Hour to run daily backup (0-23)
- `BACKUP_MINUTE`: Minute to run daily backup (0-59)

### Data Pipeline
- `GCS_BUCKET`: Google Cloud Storage bucket
- `GDRIVE_CUSTOMER_DATA`: Google Drive destination
- `DATA_SYNC_BANDWIDTH_LIMIT_MBPS`: Sync bandwidth limit
- `DATA_SYNC_HOUR`: Hour to run daily sync
- `DATA_SYNC_MINUTE`: Minute to run daily sync
- `DATA_CLEANUP_DAYS`: Delete data older than N days (0 to disable)

### Monitoring & Alerting
- `SLACK_WEBHOOK_URL`: Slack webhook for alerts (optional)
- `HEALTHCHECK_BACKUP_URL`: healthchecks.io URL for backups (optional)
- `HEALTHCHECK_DATA_SYNC_URL`: healthchecks.io URL for data sync (optional)
- `GPU_TEMP_THRESHOLD`: GPU temperature warning threshold (°C)
- `DISK_TEMP_THRESHOLD`: Disk temperature warning threshold (°C)
- `FS_USAGE_THRESHOLD`: Filesystem usage warning threshold (%)
- `SMART_MONITORING`: Enable SMART monitoring (true/false)

### Service Ports
- `CODE_SERVER_BASE_PORT`: Starting port for code-server (8443)
- `JUPYTER_BASE_PORT`: Starting port for Jupyter (8888)
- Plus ports for all system services

### Advanced Settings
- `ENABLE_SSH_2FA`: Enable 2FA for SSH (true/false)
- `ENABLE_AUDITD`: Enable auditd for security auditing (true/false)
- `ENABLE_UPS_MONITORING`: Enable UPS monitoring (true/false)
- `ENABLE_GPU_TIMESLICING`: Enable GPU time-slicing (true/false)
- `ENABLE_AUTO_UPDATES`: Enable automatic security updates (true/false)

## Configuration Validation

**Before running any setup scripts**, validate your configuration:

```bash
./scripts/00-validate-config.sh
```

This checks:
- All required settings are present
- Numeric values are valid
- RAID level matches disk count
- Devices exist (if specified)
- User list is valid

Example output:
```
=== ML Training Server - Configuration Validation ===

Checking required settings...
  ✓ Users configured: john jane mike (3 users)
  ✓ Mount point: /mnt/storage

Checking storage configuration...
  ✓ SSD/NVMe: /dev/nvme0n1
    Size: 1000GB
  ✓ HDDs detected: 4
    - /dev/sdb: 20000GB
    - /dev/sdc: 20000GB
    - /dev/sdd: 20000GB
    - /dev/sde: 20000GB

Checking RAID configuration...
  ✓ RAID10 with 4 disks

Checking network configuration...
  ✓ Domain: example.com

=== Validation Summary ===
Errors: 0
Warnings: 0

✅ Configuration is valid!
```

## Example Configurations

### Small Setup (2 users, 2 disks)
```bash
USERS="admin user1"
HDD_DEVICES="/dev/sdb /dev/sdc"
BTRFS_RAID_LEVEL="raid1"
BCACHE_MODE="writethrough"
```

### Medium Setup (3 users, 3 disks, no SSD)
```bash
USERS="alice bob charlie"
NVME_DEVICE=""  # No SSD/NVMe
HDD_DEVICES="/dev/sdb /dev/sdc /dev/sdd"
BTRFS_RAID_LEVEL="raid1"
BCACHE_MODE="none"  # Disable bcache
```

### Large Setup (10 users, 6 disks)
```bash
USERS="u1 u2 u3 u4 u5 u6 u7 u8 u9 u10"
HDD_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg"
BTRFS_RAID_LEVEL="raid10"
MEMORY_GUARANTEE_GB=16  # Less RAM per user
MEMORY_LIMIT_GB=64
```

### Single Disk Setup (for testing)
```bash
USERS="testuser"
HDD_DEVICES="/dev/sdb"
BTRFS_RAID_LEVEL="single"
BCACHE_MODE="none"
```

## Generating Docker Compose

After configuring users, generate the docker-compose.yml:

```bash
cd docker
./generate-compose.sh
```

This creates services for all configured users automatically.

## Scripts That Use Configuration

All setup scripts read from `config.sh`:

1. **00-validate-config.sh** - Validates configuration
2. **01-setup-storage.sh** - Uses storage, RAID, bcache settings
3. **02-setup-users.sh** - Uses user list and UID settings
4. **03-setup-docker.sh** - Uses Docker settings
5. **04-setup-cloudflare-tunnel.sh** - Uses domain and user list
6. **05-setup-firewall.sh** - Uses network settings
7. **06-setup-monitoring.sh** - Uses monitoring settings and user list
8. **07-setup-backups.sh** - Uses backup settings
9. **09-setup-data-pipeline.sh** - Uses data pipeline settings

The **docker/generate-compose.sh** script creates per-user services.

## Updating Configuration

To change configuration after initial setup:

1. **Edit config.sh**
2. **Regenerate docker-compose** (if users changed):
   ```bash
   cd docker
   ./generate-compose.sh
   docker compose down
   docker compose up -d
   ```
3. **Re-run affected scripts** if needed

**Note:** Storage configuration cannot be changed after `01-setup-storage.sh` without wiping disks!

## Troubleshooting

**Configuration not found:**
```
ERROR: Configuration file not found
```
→ Run `cp config.sh.example config.sh` first

**Validation fails:**
```
✗ ERROR: RAID10 requires at least 4 disks, found 2
```
→ Change to `BTRFS_RAID_LEVEL="raid1"` or add more disks

**Auto-detection not finding devices:**
```
⚠ WARNING: No HDDs detected
```
→ Manually specify devices in `HDD_DEVICES`

## Best Practices

1. **Always validate** before running setup: `./scripts/00-validate-config.sh`
2. **Backup config.sh** - it's your entire system configuration
3. **Use auto-detection** unless you have specific requirements
4. **Match RAID level to disk count:**
   - 2-3 disks → RAID1
   - 4+ disks → RAID10
5. **Enable bcache** only if you have a UPS (for writeback mode)
6. **Start with conservative resource limits** and adjust based on usage

## Support

- See [SETUP-GUIDE.md](SETUP-GUIDE.md) for detailed setup instructions
- See [QUICKSTART.md](QUICKSTART.md) for fast setup
- See [scripts/README.md](scripts/README.md) for script documentation
