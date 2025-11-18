# ML Training Server Setup Guide

> **Note**: This is a detailed installation and operations manual. For an overview of the system, costs, and architecture, see [README.md](README.md).

Complete guide for setting up a 5-user on-premise ML training server replacing GCP GCE infrastructure.

## Table of Contents

1. [Storage Setup](#storage-setup)
2. [Shared Caches Setup](#shared-caches-setup)
3. [User Account Setup](#user-account-setup)
4. [Docker and Container Setup](#docker-and-container-setup)
5. [Services Deployment](#services-deployment)
6. [Networking and Security](#networking-and-security)
7. [Monitoring and Alerting](#monitoring-and-alerting)
8. [Backup Configuration](#backup-configuration)
9. [Data Pipeline Setup](#data-pipeline-setup)
10. [Testing and Validation](#testing-and-validation)
11. [Maintenance](#maintenance)
12. [Troubleshooting](#troubleshooting)

---

## Storage Setup

### Prerequisites and Warnings

**IMPORTANT: Read before proceeding**

- **Dedicated server required**: This setup assumes the server is dedicated to ML training. Dual-boot systems (e.g., Windows/Linux) or servers with multiple OS installations are NOT supported.
- **Partition management**: The storage scripts automatically partition disks and assume full control of the NVMe/SSD and all HDDs. Non-standard partition layouts (recovery partitions, custom disk configurations) may cause failures.
- **Fresh OS installation**: For best results, install Ubuntu Server 24.04 LTS or Debian 12+ as the only operating system before running these scripts.
- **Data loss warning**: The storage setup will format all specified disks. Ensure you have backups of any important data.

### Automated Setup

Run the storage setup script:

```bash
cd ~/train-server/scripts
sudo ./01-setup-storage.sh
```

This script will:
1. Partition the NVMe (100GB OS, the rest for bcache)
2. Create BTRFS RAID10 across all HDD
3. Configure bcache in writeback mode
4. Create directory structure
5. Configure mount points in /etc/fstab
6. Enable BTRFS monthly scrub

### Manual Verification

```bash
# Check BTRFS status
sudo btrfs filesystem show
sudo btrfs filesystem df /mnt/storage

# Check bcache status
cat /sys/block/bcache0/bcache/cache_mode  # Should show "writeback"
cat /sys/block/bcache0/bcache/stats_total/cache_hits

# Check mount points
df -h
mount | grep /mnt/storage
```

### Directory Structure

After setup, you should have:
```
/mnt/storage/
├── homes/              # User home directories (backed up)
├── workspaces/         # User scratch space (persistent but NOT backed up)
├── shared/             # Mount point for Google Drive Shared Drive
├── docker-volumes/     # Persistent container data (backed up)
├── cache/
│   └── gdrive/         # Cache for Google Drive
└── snapshots/          # BTRFS snapshots (local only)
```

### Google Drive Shared Drive Setup

> **See also**: [POST-DEPLOYMENT/GOOGLE-DRIVE.md](POST-DEPLOYMENT/GOOGLE-DRIVE.md) for managing shared drive operations, cache management, and troubleshooting.

The `/shared` directory should be mounted from a Google Workspace Shared Drive with local caching for near-disk performance.

**Run the Google Drive setup script:**

```bash
cd ~/train-server/scripts
sudo ./02-setup-gdrive-shared.sh
```

This script will:
1. Install rclone (if not already installed)
2. Configure OAuth access to Google Workspace Shared Drive
3. Create local cache directory
4. Mount Shared Drive to `/mnt/storage/shared` with VFS cache
5. Configure systemd service for automatic mounting on boot
6. Setup health monitoring (checks mount every 5 minutes)

**Configuration details:**
- **Cache mode**: Full VFS cache (files downloaded on first access, cached locally)
- **Cache size**: 80% of remaining BTRFS space after user data + snapshots (auto-calculated)
- **Cache expiry**: 30 days (LRU eviction)
- **Performance**: First access downloads from cloud (~10-100 MB/s), subsequent access is near-local speed
- **Auto-recovery**: Systemd service restarts on failure

**Verify the mount:**

```bash
# Check mount status
systemctl status gdrive-shared.service
mountpoint /mnt/storage/shared

# Test access
ls /mnt/storage/shared

# View cache stats
/opt/scripts/monitoring/gdrive-cache-stats.sh
```

**Management commands:**
```bash
# View logs
journalctl -u gdrive-shared.service -f
tail -f /var/log/gdrive-shared.log

# Restart mount
sudo systemctl restart gdrive-shared.service

# Check health
/opt/scripts/monitoring/check-gdrive-mount.sh
```

---

## Shared Caches Setup

**Run the shared caches setup script:**

```bash
cd ~/train-server/scripts
sudo ./03-setup-shared-caches.sh
```

This script configures shared caching directories for:
- **Python packages**: pip wheels, conda packages
- **ML models**: HuggingFace Hub, PyTorch Hub, TensorFlow Hub
- **Language package managers**: Go modules, npm, cargo, Julia, R packages
- **Build caches**: Docker layers, BuildKit cache
- **APT packages**: System package cache

**Benefits:**
- When one user downloads a model or package, all users can access it instantly
- Saves 80% bandwidth and 10-100x time for repeated installations
- Reduces redundant downloads across user workspaces

**Cache locations:**
```
/mnt/storage/cache/
├── pip/           # Python pip cache
├── conda/         # Conda package cache
├── huggingface/   # HuggingFace models
├── torch/         # PyTorch Hub models
├── apt/           # APT package cache
├── go/            # Go modules
├── npm/           # Node.js packages
└── docker/        # Docker build cache
```

---

## User Account Setup

> **See also**: [POST-DEPLOYMENT/USER-MANAGEMENT.md](POST-DEPLOYMENT/USER-MANAGEMENT.md) for adding/removing users and managing permissions after initial setup.

**Run the user setup script:**

```bash
cd ~/train-server/scripts
sudo ./04-setup-users.sh
```

This script will:
1. Create Linux users with UIDs 1000-1004
2. Add users to docker and sudo groups
3. Create home directories in /mnt/storage/homes/
4. Create workspace directories in /mnt/storage/workspaces/
5. Set up SSH key authentication (keys only, no passwords)

### Manual User Setup (if needed)

```bash
# Create user
sudo useradd -m -u 1000 -s /bin/bash alice
sudo usermod -aG docker,sudo alice

# Set password
sudo passwd alice

# Create directories
sudo mkdir -p /mnt/storage/homes/alice
sudo mkdir -p /mnt/storage/workspaces/alice
sudo mkdir -p /mnt/storage/docker-volumes/alice-state
sudo mkdir -p /mnt/storage/shared/tensorboard/alice
sudo chown -R alice:alice /mnt/storage/homes/alice /mnt/storage/workspaces/alice

# Add SSH key
sudo mkdir -p /mnt/storage/homes/alice/.ssh
sudo nano /mnt/storage/homes/alice/.ssh/authorized_keys
sudo chmod 700 /mnt/storage/homes/alice/.ssh
sudo chmod 600 /mnt/storage/homes/alice/.ssh/authorized_keys
sudo chown -R alice:alice /mnt/storage/homes/alice/.ssh
```

---

## Docker and Container Setup

### Storage Driver Requirements

**IMPORTANT: Docker storage driver compatibility**

The setup script automatically configures Docker to use the appropriate storage driver based on your filesystem:

- **BTRFS filesystem** → Uses `btrfs` storage driver (best performance, native CoW support)
- **ext4/xfs filesystem** → Uses `overlay2` storage driver (recommended, stable)

**Legacy drivers NOT supported**: Do not manually configure `devicemapper`, `aufs`, or other deprecated drivers, as they cause severe performance degradation and stability issues with BTRFS.

### Install Docker and NVIDIA Container Toolkit

```bash
cd ~/train-server/scripts
sudo ./05-setup-docker.sh
```

This installs:
- Docker Engine (latest stable)
- Docker Compose v2
- nvidia-container-toolkit
- Configures Docker daemon with appropriate storage driver

### Verify Installation

```bash
# Test Docker
docker --version
docker compose version
sudo docker run hello-world

# Verify storage driver (should be 'btrfs' or 'overlay2')
docker info | grep "Storage Driver"

# Test NVIDIA runtime
sudo docker run --rm --gpus all nvidia/cuda:13.0.1-base-ubuntu24.04 nvidia-smi
```

---

## Services Deployment

> **See also**: [POST-DEPLOYMENT/CONTAINER-MANAGEMENT.md](POST-DEPLOYMENT/CONTAINER-MANAGEMENT.md) for managing containers, rebuilding images, and troubleshooting services.

All services run in Docker containers orchestrated by Docker Compose.

### Services Overview

**Infrastructure Services (Shared):**
- **Traefik**: Reverse proxy and hostname-based routing
- **Netdata**: Real-time system monitoring + SMART disk health
- **Prometheus + Grafana**: Metrics collection and visualization
- **FileBrowser**: Web-based file management
- **Dozzle**: Container log viewer
- **Portainer**: Container management UI
- **TensorBoard**: Shared training log visualization

**Per-User Workspaces (One Container Each):**

Each user gets ONE comprehensive container (e.g., `workspace-alice`) that functions like a full virtual machine:

- **Full KDE Plasma Desktop** - Complete graphical environment
- **Remote Access**:
  - Apache Guacamole gateway (browser-based, primary method)
  - Kasm Workspaces (container streaming, alternative)
  - TigerVNC server (ports 5900+, for Guacamole backend and direct VNC)
  - XRDP server (ports 3389+, for direct RDP access)
  - noVNC HTML5 (ports 6080+, browser VNC without gateway)
  - SSH server (ports 2222+)
- **Development Tools**:
  - VS Code (via code-server, accessed through Traefik)
  - PyCharm Community Edition
  - Jupyter Lab (accessed through Traefik)
  - VSCodium
- **Multiple Languages**: Python 3.11+, Go, Rust, Julia, R, Node.js
- **GUI Applications**: Firefox, Chromium, LibreOffice, GIMP, Inkscape
- **Docker-in-Docker**: Run containers inside your workspace
- **Persistent Storage**: Home directory mounted from /mnt/storage/homes/

This architecture replaces the old multi-container approach (separate containers for code-server, jupyter, etc.) with a unified VM-like experience where all tools share state and users can run any GUI application.

### Deploy Services

```bash
cd ~/train-server/docker
sudo docker compose up -d
```

Per-user CPU and memory limits are now enforced automatically via Docker Compose `mem_limit`, `mem_reservation`, and `cpus` settings sourced from `.env` (`MEMORY_LIMIT_GB`, `MEMORY_GUARANTEE_GB`, `CPU_LIMIT`). No Swarm mode or `--compatibility` flag is required.

### Verify Services

```bash
# Check all containers are running
sudo docker compose ps

# Check Traefik dashboard
curl http://localhost:8080

# Check service logs
sudo docker compose logs traefik
sudo docker compose logs netdata
```

---

## Networking and Security

> **See also**: [POST-DEPLOYMENT/NETWORK-AND-ACCESS.md](POST-DEPLOYMENT/NETWORK-AND-ACCESS.md) for managing network configuration, DNS, and access control.

### Network Architecture Overview

The server uses a hybrid architecture providing both secure remote access and fast local access:

```
Remote Users                    Local Users
     |                                |
     | HTTPS                          | HTTP/HTTPS
     v                                v
Cloudflare Edge ──────────────> Local DNS/Hosts
     |                                |
     | Cloudflare Tunnel              | Direct
     | (encrypted)                    v
     v                          [Server IP:80]
[Server: cloudflared] ───────────────┘
     |
     v
[Traefik :80] ───> Routes by hostname
     |
     ├──> alice-code.domain.com  -> Alice's VS Code
     ├──> alice-jupyter.domain.com -> Alice's Jupyter
     └──> ... (all other services)
```

**Benefits:**
- Remote users: Secure access via Cloudflare Tunnel (zero exposed ports)
- Local users: Direct connection to server (full LAN speed, no internet roundtrip)
- Single URL scheme: Same URLs work both remotely and locally
- Automatic optimization: Local DNS/hosts file routes office users directly

**How it works:**
1. Remote users → DNS resolves to Cloudflare → Tunnel → Traefik → Services
2. Local users → Local DNS → Traefik directly → Services (bypasses internet)

### Cloudflare Tunnel Setup

1. **Create Cloudflare Tunnel**
   - Log in to Cloudflare Zero Trust dashboard
   - Navigate to Access > Tunnels
   - Create a new tunnel named `ml-train-server`
   - Install cloudflared:

   ```bash
   cd ~/train-server/scripts
   sudo ./06-setup-cloudflare-tunnel.sh
   ```

2. **Configure Public Hostname**

   In the Cloudflare Zero Trust dashboard, configure the tunnel to route **all traffic** through Traefik:

   ```
   *.yourdomain.com → http://localhost:80
   ```

   Traefik handles all hostname-based routing internally. This single wildcard entry routes:
   - `health.yourdomain.com` → Netdata
   - `prometheus.yourdomain.com` → Prometheus
   - `grafana.yourdomain.com` → Grafana
   - `alice.yourdomain.com` → Alice's desktop
   - `alice-code.yourdomain.com` → Alice's VS Code
   - `alice-jupyter.yourdomain.com` → Alice's Jupyter
   - All other services configured in Traefik

   **Benefits:**
   - Single tunnel endpoint (simpler configuration)
   - Add new services by updating Traefik config, not Cloudflare
   - Consistent routing for both local and remote users

3. **Configure Cloudflare Access**
   - Enable Google Workspace authentication (includes 2FA enforcement)
   - Create access policies for each service

### Local Network Setup (Optional but Recommended)

For users on the same local network, configure direct access to bypass the internet:

**Option A: Local DNS (Best for multiple users)**
```bash
# On your router or DNS server, add wildcard A record:
*.yourdomain.com -> 192.168.1.100  # Replace with your server's IP
```

**Option B: /etc/hosts File (Per-machine)**
```bash
# On each local machine, edit /etc/hosts (Linux/Mac)
# or C:\Windows\System32\drivers\etc\hosts (Windows)
192.168.1.100 alice-code.yourdomain.com
192.168.1.100 alice-jupyter.yourdomain.com
192.168.1.100 health.yourdomain.com
192.168.1.100 metrics.yourdomain.com
# ... add all subdomains you use
```

After configuration, local users get:
- Full LAN speed (typically 1 Gbps vs 100-300 Mbps via Cloudflare)
- Lower latency (< 1ms vs 20-100ms)
- Works even if internet is down
- Same URLs as remote users

### Firewall Configuration

```bash
cd ~/train-server/scripts
sudo ./07-setup-firewall.sh
```

This configures:
- UFW: Deny all incoming, allow outgoing
- fail2ban: SSH brute force protection
- Only Cloudflare Tunnel connects out

### SSH Configuration

SSH is configured automatically by the user setup script with:
- Key-based authentication only (no passwords)
- Root login disabled
- PAM enabled for user account integration

The configuration is located at `/etc/ssh/sshd_config.d/ml-train-server.conf`

---

## Monitoring and Alerting

> **See also**: [POST-DEPLOYMENT/MONITORING-ALERT.md](POST-DEPLOYMENT/MONITORING-ALERT.md) for monitoring dashboards, alert configuration, and operational procedures.

### Prometheus Configuration

Prometheus scrapes metrics from:
- nvidia-smi exporter (GPU metrics)
- node-exporter (system metrics)
- cAdvisor (container metrics)

Configuration is in [docker/prometheus/prometheus.yml](docker/prometheus/prometheus.yml)

### Grafana Dashboards

1. Access Grafana at `grafana.yourdomain.com`
2. Login with admin credentials (see docker/.env)
3. Add Prometheus data source: `http://prometheus:9090`
4. Import dashboards:
   - GPU Dashboard (ID: TBD)
   - Node Exporter Full (ID: 1860)
   - Docker Container Metrics (ID: 193)

### Telegram Alerts

Configure Telegram bot in config.sh or environment:

```bash
TELEGRAM_BOT_TOKEN="your_bot_token_here"
TELEGRAM_CHAT_ID="your_chat_id_here"
```

Alerts are sent for:
- Disk SMART warnings (critical)
- GPU temperature >80°C (warning)
- Container OOM kills (warning)
- Backup failures (critical)
- Filesystem >90% full (warning)
- User exceeds 1TB quota >7 days (warning)

### Setup Monitoring Scripts

```bash
cd ~/train-server/scripts
sudo ./08-setup-monitoring.sh
```

This installs:
- smartmontools with daily checks
- Custom BTRFS health check
- Per-user disk quota checker
- GPU temperature monitor
- All cron jobs for automated monitoring

---

## Backup Configuration

> **See also**: [POST-DEPLOYMENT/BACKUP-RESTORE.md](POST-DEPLOYMENT/BACKUP-RESTORE.md) for ongoing backup operations, restore procedures, and disaster recovery.

### Backup Strategy

**Tier 1: Local BTRFS Snapshots**
- 24 hourly snapshots
- 7 daily snapshots
- 4 weekly snapshots

**Tier 2: Restic to GDrive**
- Daily backup at 6 AM
- 100 Mbps bandwidth limit
- 7 daily + 52 weekly retention

### Setup Backups

```bash
cd ~/train-server/scripts
sudo ./09-setup-backups.sh
```

This configures:
1. BTRFS snapshot schedule (via cron)
2. Restic repository on GDrive
3. Daily backup script with container pause/resume
4. Monthly restore verification
5. healthchecks.io integration

### Manual Backup Test

```bash
# Create BTRFS snapshot
sudo /opt/scripts/backup/create-snapshot.sh

# Run Restic backup
sudo /opt/scripts/backup/restic-backup.sh

# List backups
sudo restic -r rclone:gdrive:backups/ml-train-server snapshots

# Restore test
sudo /opt/scripts/backup/verify-restore.sh
```

### Backup Locations

**Backed up:**
- `/mnt/storage/homes/` (user home directories)
- `/mnt/storage/docker-volumes/` (persistent container data)
- `/mnt/storage/shared/tensorboard/` (training logs)

**NOT backed up:**
- `/mnt/storage/workspaces/` (persistent, but not backed up - users responsible for reproducible data)
- `/mnt/storage/shared/` (data already in Google Drive cloud)
- Docker images (reproducible from Dockerfiles)

---

## Data Pipeline Setup

### GCS to GDrive Migration (One-Time)

For the 50TB migration, use a temporary GCE instance to avoid egress charges:

```bash
# On a GCE instance in the same region
cd ~/train-server/scripts
./gcs-to-gdrive-migration.sh
```

This uses rclone to:
1. Copy from GCS to GCE instance disk
2. Upload to GDrive in chunks
3. Verify checksums
4. Clean up temp files

Estimated time: 7-10 days at 100 Mbps

### Daily Customer Data Ingestion

After migration, daily sync runs at 4 AM:

```bash
cd ~/train-server/scripts
sudo ./10-setup-data-pipeline.sh
```

This configures:
- rclone sync from GCS to GDrive (bandwidth limited to 100 Mbps)
- Cron job at 4 AM daily
- Telegram alerts on failure
- Incremental sync (only new files)

### Manual Data Sync

```bash
# Sync customer data
sudo /opt/scripts/data/sync-customer-data.sh

# Check sync status
sudo journalctl -u customer-data-sync -f
```

---

## Testing and Validation

### System Tests

Run the comprehensive test suite:

```bash
cd ~/train-server/scripts
sudo ./11-run-tests.sh
```

This tests:
- [ ] Storage: BTRFS RAID10 health, bcache mode
- [ ] GPU: nvidia-smi, CUDA toolkit, GPU compute
- [ ] Docker: All containers running, health checks
- [ ] Network: Internet connectivity, Cloudflare tunnel
- [ ] Monitoring: Prometheus targets, Grafana dashboards
- [ ] Backups: BTRFS snapshots, Restic repository
- [ ] Alerts: Test Telegram bot delivery
- [ ] Per-user services: SSH, code-server, Jupyter access

---

## Maintenance

> **See also**: [POST-DEPLOYMENT/MAINTENANCE.md](POST-DEPLOYMENT/MAINTENANCE.md) for detailed maintenance procedures, automation scripts, and schedules.

### Daily Tasks
- Check Telegram for alerts
- Review Grafana dashboards for anomalies
- Monitor Netdata for disk health

### Weekly Tasks
- Review backup logs: `sudo journalctl -u restic-backup`
- Check disk usage: `sudo btrfs filesystem df /mnt/storage`
- Review container logs in Dozzle
- Check GPU utilization trends in Grafana

### Monthly Tasks
- Verify backup restore (automated, check results)
- Review BTRFS scrub results: `sudo btrfs scrub status /mnt/storage`
- Update packages: `sudo apt update && sudo apt upgrade`
- Review user disk quotas and send reminders if needed
- Check UPS battery health

### Quarterly Tasks
- Review and update Docker images
- Test failover scenarios (UPS, network outage)
- Review access logs for security
- Plan hardware upgrades if needed

---

### Automated Schedules

**BTRFS Snapshots:**
- Hourly: Every hour (keep 24)
- Daily: 2 AM (keep 7)
- Weekly: Sunday 3 AM (keep 4)

**Restic Backups:**
- Daily: 6 AM
- Restore verification: 1st of month, 8 AM

**Monitoring Checks:**
- SMART: Daily 3 AM
- BTRFS health: Every 6 hours
- GPU temperature: Every 15 minutes
- OOM kills: Every 30 minutes
- User quotas: Daily 6:25 AM

**Data Pipeline:**
- Customer data sync: Daily 4 AM

### Log Files

- Backup: `/var/log/restic-backup.log`
- Data sync: `/var/log/customer-data-sync.log`
- OOM kills: `/var/log/oom-kills.log`
- System services: `journalctl -u <service-name>`

---

## Troubleshooting

> **See also**: [POST-DEPLOYMENT/TROUBLESHOOTING.md](POST-DEPLOYMENT/TROUBLESHOOTING.md) for comprehensive troubleshooting guides and solutions.

### Storage Issues

**Bcache not in writeback mode:**
```bash
echo writeback | sudo tee /sys/block/bcache0/bcache/cache_mode
```

**BTRFS balance stuck:**
```bash
# Check status
sudo btrfs balance status /mnt/storage

# Cancel if needed
sudo btrfs balance cancel /mnt/storage
```

### GPU Issues

**nvidia-smi not found:**
```bash
# Reinstall drivers
sudo apt install -y nvidia-driver-550
sudo reboot
```

**CUDA version mismatch:**
```bash
# Check versions
nvidia-smi  # Driver version
nvcc --version  # CUDA toolkit version
# Update container base images if needed
```

### Container Issues

**Service won't start:**
```bash
# Check logs
sudo docker compose logs <service-name>

# Restart service
sudo docker compose restart <service-name>

# Full restart
sudo docker compose down && sudo docker compose up -d
```

### Network Issues

**Cloudflare tunnel disconnected:**
```bash
# Check status
sudo systemctl status cloudflared

# Restart tunnel
sudo systemctl restart cloudflared

# Check logs
sudo journalctl -u cloudflared -f
```

### Backup Issues

**Restic backup failing:**
```bash
# Check repository
sudo restic -r rclone:gdrive:backups/ml-train-server check

# Unlock if locked
sudo restic -r rclone:gdrive:backups/ml-train-server unlock

# Rebuild index if corrupted
sudo restic -r rclone:gdrive:backups/ml-train-server rebuild-index
```
