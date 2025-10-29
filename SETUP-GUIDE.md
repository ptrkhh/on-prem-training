# ML Training Server Setup Guide

Complete guide for setting up a 5-user on-premise ML training server replacing GCP GCE infrastructure.

## Table of Contents

1. [Hardware Assembly](#hardware-assembly)
2. [Initial OS Installation](#initial-os-installation)
3. [Storage Setup](#storage-setup)
4. [User Account Setup](#user-account-setup)
5. [Docker and Container Setup](#docker-and-container-setup)
6. [Services Deployment](#services-deployment)
7. [Networking and Security](#networking-and-security)
8. [Monitoring and Alerting](#monitoring-and-alerting)
9. [Backup Configuration](#backup-configuration)
10. [Data Pipeline Setup](#data-pipeline-setup)
11. [Testing and Validation](#testing-and-validation)
12. [Maintenance](#maintenance)

---

## Hardware Assembly

### Components Checklist
- [ ] CPU: AMD Threadripper (already owned)
- [ ] RAM: 200GB DDR5 (upgrade from 64GB)
- [ ] GPU: RTX 5080 (already owned)
- [ ] Storage: 1TB NVMe + 4x 20TB HDD
- [ ] UPS: 1500VA
- [ ] Adequate cooling in air-conditioned room

### Assembly Steps

1. **Install CPU and RAM**
   - Install Threadripper according to manufacturer instructions
   - Install all 200GB DDR5 RAM modules
   - Enable XMP/DOCP in BIOS if applicable

2. **Install Storage**
   - Install 1TB NVMe in primary M.2 slot
   - Install 4x 20TB HDDs in SATA ports
   - Note device names (will be /dev/nvme0n1, /dev/sda, /dev/sdb, /dev/sdc, /dev/sdd)

3. **Install GPU**
   - Install RTX 5080 in PCIe x16 slot with best airflow
   - Connect power cables from PSU

4. **Connect UPS**
   - Connect UPS to wall outlet
   - Connect server PSU to UPS
   - Install UPS monitoring software later

5. **BIOS Configuration**
   - Enable IOMMU/VT-d for GPU passthrough support
   - Set boot priority to NVMe
   - Enable fan curves for optimal cooling
   - Enable resume after power loss

---

## Initial OS Installation

### Prerequisites
- Ubuntu 24.04 LTS ISO on USB drive
- Keyboard, monitor temporarily connected
- Network cable connected

### Installation Steps

1. **Boot from USB**
   - Select "Install Ubuntu Server" or "Install Ubuntu Desktop" (Server recommended)

2. **Disk Partitioning**
   - Select manual partitioning
   - Use only the 1TB NVMe for now:
     - 1GB EFI System Partition (/boot/efi)
     - Remaining space as single partition (will split later)
   - DO NOT format the 4x 20TB HDDs yet

3. **Basic Configuration**
   - Hostname: `ml-train-server`
   - Admin user: `admin` (temporary, for setup only)
   - Enable OpenSSH server
   - No additional packages yet

4. **First Boot**
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y git curl wget vim tmux htop
   ```

5. **Clone this repository**
   ```bash
   cd ~
   git clone <your-repo-url> train-server
   cd train-server
   ```

---

## Storage Setup

The storage architecture uses:
- **NVMe**: 100GB for OS, 900GB for bcache (writeback mode)
- **4x20TB HDD**: BTRFS RAID10 with zstd:3 compression

### Automated Setup

Run the storage setup script:

```bash
cd ~/train-server/scripts
sudo ./01-setup-storage.sh
```

This script will:
1. Partition the NVMe (100GB OS, 900GB bcache)
2. Create BTRFS RAID10 across 4x 20TB HDDs
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

### Google Drive Shared Drive Setup (Recommended)

The `/shared` directory should be mounted from a Google Workspace Shared Drive with local caching for near-disk performance.

**Run the Google Drive setup script:**

```bash
cd ~/train-server/scripts
sudo ./01b-setup-gdrive-shared.sh
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
- **Cache size**: 80% of available BTRFS storage (configurable)
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

See `/root/GDRIVE-SHARED-GUIDE.md` for detailed usage and troubleshooting.

### Storage Architecture Explained

The system uses a two-tier storage strategy for each user:

**Tier 1: `/home/${USERNAME}` (Backed Up Daily)**
- **Purpose:** Precious, irreplaceable files
- **Contents:** Code repositories, configs, dotfiles, papers, virtual environments, small datasets
- **Size limit:** ~100GB per user (soft limit, users get reminders)
- **Backup:** Daily to GDrive via Restic (7 daily + 52 weekly snapshots)
- **Performance:** Fast (bcache-accelerated BTRFS)
- **Mounted in container as:** `/home/${USERNAME}`

**Tier 2: `/workspace` (NOT Backed Up)**
- **Purpose:** Fast scratch space for expendable/reproducible data
- **Contents:** Training data, model checkpoints, experiment outputs, large datasets
- **Size limit:** ~1TB per user (soft limit, users get reminders)
- **Backup:** NOT backed up (too large, data is reproducible or re-downloadable)
- **Performance:** Fastest (bcache-accelerated BTRFS, same as home but no backup overhead)
- **Mounted in container as:** `/workspace`

**Why Separate Them?**

1. **Backup Efficiency:** Only back up what matters (code/configs), not multi-TB datasets
2. **Clear Mental Model:** Users know what's safe vs what needs re-downloading
3. **Cost Savings:** GDrive storage costs based on backed-up data
4. **Faster Restores:** Restoring 100GB of code is fast; restoring 5TB of checkpoints is slow

**User Guidance:**
- "Put your code in `~` (home), put your data in `/workspace`"
- "If the server dies, your code is safe. Your training checkpoints? Re-train or re-download."
- "Store final model weights in `~` after training completes"

---

## User Account Setup

Create 5 user accounts: alice, bob, charlie, dave, eve

Run the user setup script:

```bash
cd ~/train-server/scripts
sudo ./02-setup-users.sh
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

### Install Docker and NVIDIA Container Toolkit

```bash
cd ~/train-server/scripts
sudo ./03-setup-docker.sh
```

This installs:
- Docker Engine (latest stable)
- Docker Compose v2
- nvidia-container-toolkit
- Configures Docker daemon

### Verify Installation

```bash
# Test Docker
docker --version
docker compose version
sudo docker run hello-world

# Test NVIDIA runtime
sudo docker run --rm --gpus all nvidia/cuda:13.0.1-base-ubuntu24.04 nvidia-smi
```

---

## Services Deployment

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
   sudo ./04-setup-cloudflare-tunnel.sh
   ```

2. **Configure Public Hostnames**
   Map these subdomains to local services:

   ```
   health.yourdomain.com       → http://localhost:19999 (Netdata)
   prometheus.yourdomain.com   → http://localhost:9090 (Prometheus)
   grafana.yourdomain.com      → http://localhost:3000 (Grafana)
   tensorboard.yourdomain.com  → http://localhost:6006 (TensorBoard)
   files.yourdomain.com        → http://localhost:8081 (FileBrowser)
   logs.yourdomain.com         → http://localhost:8082 (Dozzle)
   portainer.yourdomain.com    → http://localhost:9000 (Portainer)
   alice-code.yourdomain.com   → http://localhost:8443 (code-server alice)
   bob-code.yourdomain.com     → http://localhost:8444 (code-server bob)
   # ... repeat for charlie, dave, eve
   alice-jupyter.yourdomain.com → http://localhost:8888
   bob-jupyter.yourdomain.com   → http://localhost:8889
   # ... repeat for charlie, dave, eve
   ```

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
sudo ./05-setup-firewall.sh
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

### Prometheus Configuration

Prometheus scrapes metrics from:
- nvidia-smi exporter (GPU metrics)
- node-exporter (system metrics)
- cAdvisor (container metrics)

Configuration is in [docker/prometheus/prometheus.yml](docker/prometheus/prometheus.yml)

### Grafana Dashboards

1. Access Grafana at `metrics.yourdomain.com`
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
sudo ./06-setup-monitoring.sh
```

This installs:
- smartmontools with daily checks
- Custom BTRFS health check
- Per-user disk quota checker
- GPU temperature monitor
- All cron jobs for automated monitoring

---

## Backup Configuration

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
sudo ./07-setup-backups.sh
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
- `/mnt/storage/workspaces/` (ephemeral)
- `/mnt/storage/shared/` (customer data already in GDrive)
- Docker images (reproducible)

---

## Data Pipeline Setup

### GCS to GDrive Migration (One-Time)

For the 50TB migration, use a temporary GCE instance to avoid egress charges:

```bash
# On a GCE instance in the same region
cd ~/train-server/scripts
./08-gcs-to-gdrive-migration.sh
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
sudo ./09-setup-data-pipeline.sh
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
sudo ./10-run-tests.sh
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

### Load Testing

Simulate 5 concurrent users:

```bash
cd ~/train-server/tests
./test-concurrent-load.sh
```

Monitors:
- GPU memory allocation
- System RAM usage
- Disk I/O performance
- Network bandwidth
- Container CPU limits

---

## Maintenance

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

### Emergency Procedures

**Disk Failure:**
1. Check BTRFS status: `sudo btrfs device stats /mnt/storage`
2. If degraded, replace disk and balance: `sudo btrfs replace start /dev/sdX /dev/sdY /mnt/storage`
3. Alert users of potential slowdown during rebuild

**GPU Failure:**
1. Check dmesg and nvidia-smi logs
2. Restart nvidia drivers: `sudo systemctl restart nvidia-persistenced`
3. If hardware failure, schedule downtime for replacement

**Complete System Failure:**
1. Boot from Ubuntu USB
2. Mount BTRFS RAID: `sudo mount -o degraded /dev/sda /mnt/recovery`
3. Copy critical data to external storage
4. Restore from GDrive backup using Restic
5. Rebuild system using this guide

---

## Migration Timeline

### Month 1-2: Setup and Stabilization
- [ ] Assemble hardware
- [ ] Install OS and configure storage
- [ ] Deploy all services
- [ ] Configure networking and security
- [ ] Set up monitoring and backups
- [ ] Begin 50TB GCS → GDrive migration

### Month 3-6: Parallel Operation
- [ ] Train from GDrive data
- [ ] Customer still uploads to GCS
- [ ] Daily sync GCS → GDrive
- [ ] Monitor system stability and performance
- [ ] Optimize GPU utilization

### Month 6-11: Transition Customer Upload
- [ ] Customer uploads directly to GDrive
- [ ] Keep GCS as backup
- [ ] Reduce GCS costs by deleting old data
- [ ] Validate end-to-end pipeline

### Month 12+: Full On-Premise
- [ ] GCS only stores serving/inference data
- [ ] Training fully on-premise
- [ ] $3650+/month savings achieved

---

## Scripts Reference

All setup and maintenance scripts are in the `scripts/` directory.

### Setup Scripts (Run in Order)

1. **00-validate-config.sh** - Validate configuration before setup
   ```bash
   ./scripts/00-validate-config.sh
   ```
   Checks: Required settings, disk existence, RAID level compatibility, numeric values

2. **01-setup-storage.sh** - Configure BTRFS RAID + bcache
   ```bash
   sudo ./scripts/01-setup-storage.sh
   ```
   Creates: BTRFS RAID10, bcache, directory structure, fstab entries
   **REBOOT REQUIRED AFTER THIS STEP**

2b. **01b-setup-gdrive-shared.sh** - Mount Google Drive Shared Drive (Recommended)
   ```bash
   sudo ./scripts/01b-setup-gdrive-shared.sh
   ```
   Configures: Google Workspace Shared Drive mount /shared, cached locally
   Features: VFS cache, auto-recovery, health monitoring
   **Note**: Skip if you prefer local storage for /shared

3. **02-setup-users.sh** - Create user accounts
   ```bash
   sudo ./scripts/02-setup-users.sh
   ```
   Creates: Linux users, home directories, SSH key-based authentication

4. **03-setup-docker.sh** - Install Docker and NVIDIA runtime
   ```bash
   sudo ./scripts/03-setup-docker.sh
   ```
   Installs: Docker Engine, docker-compose, nvidia-container-toolkit

5. **04-setup-cloudflare-tunnel.sh** - Configure Cloudflare Tunnel
   ```bash
   sudo ./scripts/04-setup-cloudflare-tunnel.sh
   ```
   Creates: Cloudflare Tunnel, DNS records, systemd service

6. **05-setup-firewall.sh** - Configure firewall and security
   ```bash
   sudo ./scripts/05-setup-firewall.sh
   ```
   Configures: UFW firewall, fail2ban, automatic updates

7. **06-setup-monitoring.sh** - Set up monitoring and alerts
   ```bash
   sudo ./scripts/06-setup-monitoring.sh
   ```
   Creates: Monitoring scripts, Telegram alerts, cron jobs

8. **07-setup-backups.sh** - Configure backup system
   ```bash
   sudo ./scripts/07-setup-backups.sh
   ```
   Configures: Restic, BTRFS snapshots, backup schedules

9. **09-setup-data-pipeline.sh** - Set up data sync pipeline
   ```bash
   sudo ./scripts/09-setup-data-pipeline.sh
   ```
   Configures: GCS sync, GDrive sync, daily schedules

10. **10-run-tests.sh** - Validate complete system
    ```bash
    sudo ./scripts/10-run-tests.sh
    ```
    Tests: Storage, GPU, Docker, networking, services

### Maintenance Scripts

Located in `/opt/scripts/` after installation:

**Backup Scripts** (`/opt/scripts/backup/`):
- `create-snapshot.sh` - Create BTRFS snapshot (hourly/daily/weekly)
- `restic-backup.sh` - Backup to GDrive via Restic
- `verify-restore.sh` - Test backup restore (monthly)

**Monitoring Scripts** (`/opt/scripts/monitoring/`):
- `send-telegram-alert.sh` - Send Telegram notification
- `check-disk-smart.sh` - Monitor disk health (daily)
- `check-gpu-temperature.sh` - Monitor GPU temp (every 15 min)
- `check-btrfs-health.sh` - Check filesystem health (every 6 hours)
- `check-oom-kills.sh` - Detect OOM kills (every 30 min)
- `check-user-quotas.sh` - Check disk usage (daily)

**Data Pipeline Scripts** (`/opt/scripts/data/`):
- `sync-customer-data.sh` - Daily GCS/GDrive sync
- `manual-sync.sh` - Manual sync (no bandwidth limit)
- `cleanup-old-data.sh` - Delete old data (90+ days)

### Manual Operations

**Create snapshot:**
```bash
sudo /opt/scripts/backup/create-snapshot.sh daily
```

**Run backup manually:**
```bash
sudo /opt/scripts/backup/restic-backup.sh
```

**List Restic snapshots:**
```bash
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server snapshots
```

**Restore from backup:**
```bash
export RESTIC_PASSWORD_FILE=/root/.restic-password
restic -r rclone:gdrive:backups/ml-train-server restore latest --target /tmp/restore
```

**Manual data sync:**
```bash
sudo /opt/scripts/data/manual-sync.sh
```

**Send test alert:**
```bash
sudo /opt/scripts/monitoring/send-telegram-alert.sh info "Test message"
```

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

---

## Support and Resources

- **This Repository**: All scripts and configs
- **Ubuntu Documentation**: https://ubuntu.com/server/docs
- **Docker Documentation**: https://docs.docker.com/
- **BTRFS Wiki**: https://btrfs.wiki.kernel.org/
- **Restic Documentation**: https://restic.readthedocs.io/

For issues or questions, contact the system administrator or refer to the scripts in this repository.
