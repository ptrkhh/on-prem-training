# Setup Scripts

This directory contains all setup and maintenance scripts for the ML Training Server.

## Installation Order

Run these scripts in order during initial setup:

### 1. Storage Setup
```bash
sudo ./01-setup-storage.sh
```
- Creates BTRFS RAID10 on 4x 20TB HDDs
- Configures bcache with NVMe
- Sets up directory structure
- **REBOOT REQUIRED AFTER THIS STEP**

### 2. User Accounts
```bash
sudo ./02-setup-users.sh
```
- Creates 5 user accounts (alice, bob, charlie, dave, eve)
- Sets up SSH key authentication
- Configures 2FA (optional)
- Creates user directories

### 3. Docker and GPU
```bash
sudo ./03-setup-docker.sh
```
- Installs Docker Engine
- Installs NVIDIA drivers
- Installs nvidia-container-toolkit
- **MAY REQUIRE REBOOT**

### 4. Cloudflare Tunnel
```bash
sudo ./04-setup-cloudflare-tunnel.sh
```
- Installs cloudflared
- Creates and configures tunnel
- Routes DNS to tunnel
- Sets up all service hostnames

### 5. Firewall and Security
```bash
sudo ./05-setup-firewall.sh
```
- Configures UFW firewall
- Installs and configures fail2ban
- Enables automatic security updates
- Optional: auditd for security auditing

### 6. Monitoring and Alerting
```bash
sudo ./06-setup-monitoring.sh
```
- Installs smartmontools
- Creates monitoring scripts
- Configures Slack alerts
- Sets up cron jobs for checks

### 7. Backup Configuration
```bash
sudo ./07-setup-backups.sh
```
- Configures rclone for GDrive
- Initializes Restic repository
- Sets up BTRFS snapshots
- Creates backup schedules

### 8. Deploy Services
```bash
cd ../docker
cp .env.example .env
nano .env  # Edit passwords and domain
sudo docker compose up -d
```
- Starts all Docker services
- Traefik, Grafana, Prometheus, etc.
- Per-user Jupyter and code-server

### 9. Data Pipeline
```bash
sudo ./09-setup-data-pipeline.sh
```
- Configures rclone for GCS
- Sets up daily data sync
- Creates migration scripts

### 10. Run Tests
```bash
sudo ./10-run-tests.sh
```
- Validates all components
- Tests storage, GPU, Docker, networking
- Checks services are running

## Subdirectories

### backup/
Scripts created by `07-setup-backups.sh`:
- `create-snapshot.sh` - Create BTRFS snapshots
- `restic-backup.sh` - Backup to GDrive
- `verify-restore.sh` - Test backup restore
- `init-restic.sh` - Initialize Restic repository

### monitoring/
Scripts created by `06-setup-monitoring.sh`:
- `send-slack-alert.sh` - Send alerts to Slack
- `check-disk-smart.sh` - Monitor disk health
- `check-gpu-temperature.sh` - Monitor GPU temp
- `check-btrfs-health.sh` - Check filesystem health
- `check-oom-kills.sh` - Detect OOM kills
- `check-gpu-usage.sh` - Monitor GPU usage
- `check-user-quotas.sh` - Check user disk usage

### data/
Scripts created by `09-setup-data-pipeline.sh`:
- `gcs-to-gdrive-migration.sh` - One-time 50TB migration
- `sync-customer-data.sh` - Daily data sync
- `manual-sync.sh` - Manual sync (no bandwidth limit)
- `cleanup-old-data.sh` - Delete old data from GDrive

## Manual Operations

### Create BTRFS Snapshot
```bash
sudo /opt/scripts/backup/create-snapshot.sh daily
```

### Run Backup Manually
```bash
sudo /opt/scripts/backup/restic-backup.sh
```

### Check Restic Snapshots
```bash
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server snapshots
```

### Restore from Backup
```bash
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server restore latest --target /tmp/restore
```

### Sync Customer Data Manually
```bash
sudo /opt/scripts/data/manual-sync.sh
```

### Send Test Slack Alert
```bash
sudo /opt/scripts/monitoring/send-slack-alert.sh info "Test alert"
```

### Check Disk SMART Status
```bash
sudo /opt/scripts/monitoring/check-disk-smart.sh
```

### Monitor GPU Temperature
```bash
sudo /opt/scripts/monitoring/check-gpu-temperature.sh
```

## Cron Schedules

### BTRFS Snapshots
- Hourly: Every hour
- Daily: 2 AM
- Weekly: Sunday 3 AM

### Restic Backups
- Daily: 6 AM
- Restore verification: 1st of month, 8 AM

### Monitoring
- SMART checks: Daily 3 AM
- BTRFS health: Every 6 hours
- GPU temperature: Every 15 minutes
- OOM kills: Every 30 minutes
- GPU usage: Every hour
- User quotas: Daily 6:25 AM

### Data Pipeline
- Customer data sync: Daily 4 AM

## Logs

- Backup: `/var/log/restic-backup.log`
- Data sync: `/var/log/customer-data-sync.log`
- OOM kills: `/var/log/oom-kills.log`
- System: `journalctl -u <service-name>`

## Troubleshooting

### Storage Issues
```bash
# Check BTRFS status
sudo btrfs filesystem show
sudo btrfs filesystem df /mnt/storage
sudo btrfs device stats /mnt/storage

# Check bcache
cat /sys/block/bcache0/bcache/cache_mode
cat /sys/block/bcache0/bcache/stats_total/cache_hits

# Force writeback mode
echo writeback | sudo tee /sys/block/bcache0/bcache/cache_mode
```

### Docker Issues
```bash
# Check services
cd ../docker && sudo docker compose ps
sudo docker compose logs <service-name>

# Restart all services
sudo docker compose restart

# Full restart
sudo docker compose down && sudo docker compose up -d
```

### GPU Issues
```bash
# Check GPU
nvidia-smi

# Test in Docker
sudo docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### Backup Issues
```bash
# Check Restic repository
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server check

# Unlock if locked
restic -r rclone:gdrive:backups/ml-train-server unlock
```

## Important Files

- `/root/.restic-password` - Restic encryption password (BACKUP THIS!)
- `/root/.slack-webhook` - Slack webhook URL
- `/root/.healthchecks-url` - healthchecks.io URL for backups
- `/root/.healthchecks-data-sync-url` - healthchecks.io URL for data sync
- `/root/.cloudflared/` - Cloudflare Tunnel configuration

## Support

Refer to the main [SETUP-GUIDE.md](../SETUP-GUIDE.md) for detailed instructions.
