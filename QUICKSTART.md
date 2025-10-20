# Quick Start Guide

Fast-track setup guide for the ML Training Server. For detailed instructions, see [SETUP-GUIDE.md](SETUP-GUIDE.md).

## Prerequisites

- Ubuntu 24.04 LTS installed on 1TB NVMe
- 4x 20TB HDDs installed (not yet formatted)
- RTX 5080 GPU installed
- 200GB RAM
- Internet connection

## Setup Steps (30-60 minutes)

### 1. Clone Repository
```bash
cd ~
git clone <your-repo-url> train-server
cd train-server
```

### 2. Storage Setup (5 min)
```bash
cd scripts
sudo ./01-setup-storage.sh
# Confirm with "YES" when prompted
# REBOOT after completion
```

After reboot:
```bash
# Verify storage
df -h /mnt/storage
sudo btrfs filesystem show
```

### 3. Create Users (5 min)
```bash
cd ~/train-server/scripts
sudo ./02-setup-users.sh
# Set passwords for each user when prompted
# Add SSH public keys to /mnt/storage/homes/<user>/.ssh/authorized_keys
```

### 4. Install Docker & GPU (10 min)
```bash
sudo ./03-setup-docker.sh
# May require reboot if NVIDIA drivers are installed
```

Verify:
```bash
docker --version
nvidia-smi
sudo docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### 5. Setup Cloudflare Tunnel (5 min)
```bash
sudo ./04-setup-cloudflare-tunnel.sh
# Follow browser authentication
# Enter your domain when prompted
```

### 6. Configure Firewall (2 min)
```bash
sudo ./05-setup-firewall.sh
# Answer prompts for local network and auditd
```

### 7. Setup Monitoring (3 min)
```bash
sudo ./06-setup-monitoring.sh
# Configure Slack webhook when prompted
```

### 8. Deploy Services (5 min)
```bash
cd ~/train-server/docker
cp .env.example .env
nano .env  # Edit passwords and domain
sudo docker compose up -d
```

Verify:
```bash
sudo docker compose ps
# All services should show "Up"
```

### 9. Configure Backups (10 min)
```bash
cd ~/train-server/scripts
sudo ./07-setup-backups.sh
# Configure rclone for GDrive when prompted
# Optionally run test backup
```

### 10. Setup Data Pipeline (5 min)
```bash
sudo ./09-setup-data-pipeline.sh
# Configure rclone for GCS and GDrive
```

### 11. Run Tests (2 min)
```bash
sudo ./10-run-tests.sh
```

All tests should pass ✓

## Verify Setup

### Check Services
```bash
# Access via browser (replace with your domain):
https://metrics.yourdomain.com     # Grafana
https://health.yourdomain.com      # Netdata
https://logs.yourdomain.com        # Dozzle
https://files.yourdomain.com       # FileBrowser
https://tensorboard.yourdomain.com # TensorBoard
https://alice-code.yourdomain.com  # VS Code for Alice
https://jupyter-alice.yourdomain.com # Jupyter for Alice
```

### Test GPU Training
```bash
cd ~/train-server/tests
python3 test-gpu-training.py
```

### Check Backups
```bash
# List BTRFS snapshots
ls -la /mnt/storage/snapshots/

# List Restic snapshots
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server snapshots
```

### Check Monitoring
```bash
# GPU temperature
nvidia-smi

# Disk health
sudo smartctl -H /dev/sda

# Container logs
sudo docker compose -f ~/train-server/docker/docker-compose.yml logs -f
```

## Post-Setup Tasks

### 1. Configure Cloudflare Access
1. Go to https://one.dash.cloudflare.com/
2. Navigate to Access > Applications
3. Create access policies for each service
4. Enable Google Workspace authentication
5. Enforce 2FA

### 2. Add SSH Keys for Users
```bash
# For each user, add their public key:
sudo nano /mnt/storage/homes/alice/.ssh/authorized_keys
# Paste the public key
sudo chown alice:alice /mnt/storage/homes/alice/.ssh/authorized_keys
sudo chmod 600 /mnt/storage/homes/alice/.ssh/authorized_keys
```

### 3. Setup 2FA for SSH (Optional)
Each user should run:
```bash
google-authenticator
# Scan QR code with authenticator app
```

### 4. Start GCS to GDrive Migration
On a temporary GCE instance in the same region:
```bash
cd ~/train-server/scripts/data
./gcs-to-gdrive-migration.sh
# Edit GCS_BUCKET variable first
```

### 5. Configure Grafana Dashboards
1. Login to Grafana: https://metrics.yourdomain.com
2. Add Prometheus data source: http://prometheus:9090
3. Import dashboards:
   - Node Exporter Full (ID: 1860)
   - Docker Container Metrics (ID: 193)

### 6. Test Email Alerts
```bash
echo "Test email" | mail -s "Test" root
```

## Daily Operations

### Check System Health
```bash
# Grafana dashboard
https://metrics.yourdomain.com

# Netdata
https://health.yourdomain.com

# Check Slack for alerts
```

### Monitor Backups
```bash
# Check last backup
sudo journalctl -u restic-backup | tail -n 50

# List snapshots
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server snapshots
```

### User Disk Usage
```bash
# Check usage
sudo du -sh /mnt/storage/homes/*

# Send reminder if over 1TB
sudo /opt/scripts/monitoring/check-user-quotas.sh
```

## Troubleshooting Quick Reference

### Services Won't Start
```bash
cd ~/train-server/docker
sudo docker compose logs <service-name>
sudo docker compose restart <service-name>
```

### GPU Not Detected
```bash
nvidia-smi
sudo systemctl restart nvidia-persistenced
```

### Backup Failed
```bash
sudo journalctl -u restic-backup -n 100
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server check
```

### Disk Full
```bash
# Check usage
sudo btrfs filesystem df /mnt/storage

# Clean Docker
sudo docker system prune -a

# Clean old snapshots
sudo rm -rf /mnt/storage/snapshots/hourly_*
```

## Cost Savings Timeline

- **Before**: $2000 GCE + $2000 GCS = $4000/month
- **After**: $150 electricity + $150 GDrive + $50 hardware = $350/month
- **Savings**: $3650/month ($43,800/year)
- **Break-even**: Under 2 months

## Next Steps

1. **Month 1-2**: Stabilize system, migrate 50TB GCS → GDrive
2. **Month 3-6**: Work from GDrive, customer uploads to GCS
3. **Month 6-11**: Customer uploads to GDrive
4. **Month 12+**: Full on-premise, GCS only for serving

## Support

- **Full Guide**: [SETUP-GUIDE.md](SETUP-GUIDE.md)
- **Scripts README**: [scripts/README.md](scripts/README.md)
- **Tests**: [tests/](tests/)

For issues, check logs in `/var/log/` and `journalctl`.
