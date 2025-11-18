# ML Training Server

**Replace $4,000/month GCP infrastructure with $300/month on-premise server**

Complete automated setup for migrating 5 trusted ML Engineers from Google Cloud with 5x GCE n1-highmem-16 + T4 GPU and
shared repository in GCS to a single on-premise server. Save nearly $4,000/month ($48,000/year) while maintaining or
improving performance.

## Quick Links

- **[SETUP-GUIDE.md](SETUP-GUIDE.md)** - Complete step-by-step setup instructions
- **[config.sh.example](config.sh.example)** - Configuration template (customize users, hardware, and all settings)

## Table of Contents

- [System Requirements](#system-requirements)
- [System Overview](#system-overview)
- [Cost Savings](#cost-savings)
- [Quick Start](#quick-start)
- [Access Your Services](#access-your-services)
- [Key Features](#key-features)
- [Documentation](#documentation)
- [Example Configurations](#example-configurations)
- [Architecture](#architecture)
- [User Guide](#user-guide)
- [Admin Guide](#admin-guide)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)

## System Requirements

### Minimum Requirements

- **OS**: Fresh Ubuntu Server 22.04+ or Debian 12+ installation
- **Storage**: 2+ disks (any size, any type)
- **Users**: 1-100 users (configurable)
- **Docker**: Docker 20.10+ with overlay2 (ext4/xfs) or btrfs storage driver

### Recommended Setup (5 users)

- **CPU**: AMD Threadripper or similar (32+ cores)
- **RAM**: 200GB DDR5
- **GPU**: NVIDIA RTX 5080 or similar
- **Storage**: 1TB NVMe SSD + 4x 20TB HDD

### Critical Limitations

> ⚠️ **IMPORTANT - Read before proceeding:**

1. **Dedicated server only**: NOT compatible with dual-boot systems (Windows/Linux)
   - Storage scripts assume full control of all disks
   - Multi-OS configurations will cause setup failures or data loss

2. **Fresh OS required**: Install Ubuntu/Debian as the ONLY OS before running setup
   - Remove recovery partitions and other OS installations first

3. **Docker storage driver**: Must use `overlay2` or `btrfs` drivers
   - Legacy drivers (`devicemapper`, `aufs`) cause performance issues

**For detailed prerequisites, see [SETUP-GUIDE.md#prerequisites-and-warnings](SETUP-GUIDE.md#prerequisites-and-warnings)**

## System Overview

### Hardware (Flexible!)

- CPU: AMD Threadripper (or similar)
- RAM: 200GB DDR5 (configurable)
- GPU: RTX 5080 (or other Nvidia)
- Storage: 1TB NVMe + 4x 20TB HDD in BTRFS RAID10
- **Works with ANY disk configuration** (2-20+ disks, any sizes, any RAID level)

### Remote Desktop Access

**Primary Access Methods (Recommended):**

1. **Per-User Direct URLs** (Easiest)
   - `http://alice.yourdomain.com` - Direct desktop access
   - Zero configuration, no gateway login required
   - HTML5 browser client with full KDE Plasma desktop

2. **Apache Guacamole Gateway** (Multi-Protocol)
   - `http://guacamole.yourdomain.com`
   - Unified interface for VNC/RDP/SSH
   - Best for managing multiple users

3. **Kasm Workspaces** (Enterprise Alternative)
   - `http://kasm.yourdomain.com`
   - Container streaming platform with session recording

**Advanced: Direct Protocol Access**

For users who prefer native clients:
- **VNC**: Ports 5900+ (TigerVNC) - Use RealVNC, TightVNC, etc.
- **RDP**: Ports 3389+ (XRDP) - Use Windows Remote Desktop
- **noVNC**: Ports 6080+ - Browser-based VNC without gateway

**Recommendation**: Start with per-user URLs (option 1) for simplicity.

### Shared Cache System

All users benefit from shared package/model caches - when one user downloads, all users can access instantly:

**Cache Types:**
- ML Models: HuggingFace Hub, PyTorch Hub, TensorFlow Hub (~50-100GB)
- Packages: pip wheels, conda, APT packages (~20-40GB)
- Languages: Go modules, npm, cargo, Julia, R (~10-20GB)
- Build: Docker layers, BuildKit cache (~10-30GB)

**Impact:** First user downloads 500MB model in 30-60s → other users load instantly from cache. Saves 80% bandwidth and 10-100x time for repeated installs.

**Monitoring:** Run `/opt/scripts/cache/show-cache-info.sh` to view cache statistics

**Cleanup:** Caches grow indefinitely (except Google Drive VFS auto-evicts via LRU).

**Example - Clean old cache files (older than 90 days):**
```bash
find /mnt/storage/cache/{pip,conda,apt} -type f -mtime +90 -delete
```

### User Workspaces: One Container = One Complete Environment

Each user gets a single comprehensive container (like `workspace-alice`) that functions as a complete development machine:

**What's Included:**
- Full KDE Plasma desktop environment
- All development tools: VS Code, PyCharm, Jupyter Lab, VSCodium
- Multiple languages: Python 3.11+, Go, Rust, Julia, R, Node.js
- GUI applications: Firefox, Chromium, LibreOffice, GIMP, Inkscape
- Docker-in-Docker for running containers inside your workspace
- Persistent storage: `/home` and `/workspace` survive restarts

**Why Containers Instead of VMs?**

| Feature | Containers (Our Approach) | Traditional VMs |
|---------|---------------------------|-----------------|
| GPU Support | Universal (nvidia-container-toolkit) | Complex passthrough |
| Performance | 96%+ native GPU performance | 80-90% (hypervisor overhead) |
| Management | Single host OS + Docker | Multiple guest OS to patch |
| Startup Time | 2-5 seconds | 30-60 seconds |
| Isolation | Full (namespaces, cgroups) | Full (hardware virtualization) |

**Best of Both Worlds**: VM-like isolation with bare-metal performance, perfect for trusted team environments.

### Infrastructure Services (Shared)

- **Traefik**: Reverse proxy and router
- **Apache Guacamole**: Browser-based remote desktop gateway
- **Kasm Workspaces**: Container streaming platform
- **Netdata**: Real-time system monitoring + SMART disk monitoring
- **Prometheus + Grafana**: Metrics collection and visualization
- **Shared TensorBoard**: View all training logs
- **FileBrowser**: Web-based file management
- **Dozzle**: Container log viewer
- **Portainer**: Container management UI

### Network Architecture

- **Cloudflare Tunnel**: Secure remote access (zero exposed ports)
- **Traefik Routing**: Single URL scheme for all services
- **Local Network Optimization**: Office users bypass internet automatically
- **Cloudflare Access**: Google Workspace SSO with 2FA enforcement

### Automated Operations

- **Backups**: BTRFS snapshots (hourly/daily/weekly) + Restic to GDrive (daily)
- **Monitoring**: SMART checks, GPU temperature, BTRFS health, user quotas
- **Alerts**: Telegram notifications for critical events
- **Data Pipeline**: Daily GCS → GDrive sync with bandwidth limits

**Related Documentation:**
- [SETUP-GUIDE.md#services-deployment](SETUP-GUIDE.md#services-deployment) - Detailed service configuration
- [GRAND-PLAN.md](GRAND-PLAN.md) - Architecture decisions and rationale

## Cost Savings

| Item             | Before (GCP)   | After (On-Premise) |
|------------------|----------------|--------------------|
| Compute          | $2,000+/mo     | -                  |
| Storage          | $2,000+/mo     | -                  |
| Electricity      | -              | $100/mo            |
| GDrive Workspace | -              | $150/mo            |
| Hardware fund    | -              | $50/mo             |
| **Total**        | **$4,000+/mo** | **$300/mo**        |

Break-even: ~1.5 months (even if buying all new hardware)

## Quick Start (~2-3 hours total, 30 minutes hands-on)

**Prerequisites**: Fresh Ubuntu 22.04+ or Debian 12+ installation on dedicated hardware

```bash
# 1. Clone and configure
git clone <repo-url> train-server && cd train-server
cp config.sh.example config.sh
nano config.sh  # Edit users, domain, hardware settings

# 2. Validate and generate configs
./scripts/00-validate-config.sh
cd docker && ./generate-compose.sh && cd ..

# 3. Run setup scripts (scripts 01-10, reboot after 01)
# 4. Build and start containers
# 5. Run tests
```

**For detailed setup instructions, see [SETUP-GUIDE.md](SETUP-GUIDE.md)**

## Access Your Services

### Service URLs

**Infrastructure:**
- System Health: `http://health.yourdomain.com` (Netdata)
- Prometheus: `http://prometheus.yourdomain.com`
- Grafana: `http://grafana.yourdomain.com`
- Files: `http://files.yourdomain.com`
- Logs: `http://logs.yourdomain.com`

**Per-User (example for Alice):**
- **Desktop**: `http://alice.yourdomain.com` or `http://alice-desktop.yourdomain.com`
- VS Code: `http://alice-code.yourdomain.com`
- Jupyter: `http://alice-jupyter.yourdomain.com`
- TensorBoard: `http://alice-tensorboard.yourdomain.com`

**Shared:**
- TensorBoard: `http://tensorboard.yourdomain.com` (all users)
- Guacamole Gateway: `http://guacamole.yourdomain.com` (default: guacadmin/guacadmin)
- Kasm Workspaces: `http://kasm.yourdomain.com`

> ⚠️ **SECURITY WARNING**: Change the default Guacamole credentials (guacadmin/guacadmin) immediately after first login.

## Key Features

✅ **Universal Hardware Support**: Auto-detects disks, works with 1-100 users, any RAID level

✅ **VM-Like Experience**: Full desktop + all tools in one container per user

✅ **Hybrid Network**: Fast local access + secure remote access via Cloudflare

✅ **Production Ready**: Automated backups, monitoring, alerts, health checks

✅ **Fully Customizable**: Single config file controls everything

✅ **Cost Effective**: 91% cost reduction vs GCP

## Documentation

**Getting Started:**
- **[README.md](README.md)** - This file (overview, quick start, architecture)
- **[SETUP-GUIDE.md](SETUP-GUIDE.md)** - Complete installation and setup
- **[config.sh.example](config.sh.example)** - Configuration reference (100+ parameters)

**Operations:**
- **[POST-DEPLOYMENT/](POST-DEPLOYMENT/)** - Operational guides:
  - [BACKUP-RESTORE.md](POST-DEPLOYMENT/BACKUP-RESTORE.md) - Backup and restore procedures
  - [MONITORING-ALERT.md](POST-DEPLOYMENT/MONITORING-ALERT.md) - Monitoring and alerting
  - [TROUBLESHOOTING.md](POST-DEPLOYMENT/TROUBLESHOOTING.md) - Common issues and solutions
  - [USER-MANAGEMENT.md](POST-DEPLOYMENT/USER-MANAGEMENT.md) - Adding/removing users
  - [MAINTENANCE.md](POST-DEPLOYMENT/MAINTENANCE.md) - System maintenance tasks
  - [STORAGE-OPERATION.md](POST-DEPLOYMENT/STORAGE-OPERATION.md) - Storage management
  - [GOOGLE-DRIVE.md](POST-DEPLOYMENT/GOOGLE-DRIVE.md) - Google Drive operations
  - [NETWORK-AND-ACCESS.md](POST-DEPLOYMENT/NETWORK-AND-ACCESS.md) - Networking configuration
  - [SECURITY-OPERATION.md](POST-DEPLOYMENT/SECURITY-OPERATION.md) - Security operations
  - [CONTAINER-MANAGEMENT.md](POST-DEPLOYMENT/CONTAINER-MANAGEMENT.md) - Container operations
  - [DISASTER-RECOVERY.md](POST-DEPLOYMENT/DISASTER-RECOVERY.md) - Emergency procedures
  - [HARDWARE-CHANGE.md](POST-DEPLOYMENT/HARDWARE-CHANGE.md) - Hardware modifications
  - [PACKAGE-MANAGEMENT.md](POST-DEPLOYMENT/PACKAGE-MANAGEMENT.md) - Software updates
  - [PERFORMANCE-TUNING.md](POST-DEPLOYMENT/PERFORMANCE-TUNING.md) - Optimization guide

**Architecture:**
- **[GRAND-PLAN.md](GRAND-PLAN.md)** - Design decisions and technical rationale

## Example Configurations

### Original Spec (5 users, 1TB NVMe, 4x20TB)

```bash
USERS="alice bob charlie dave eve"
NVME_DEVICE="/dev/nvme0n1"
HDD_DEVICES="/dev/sda /dev/sdb /dev/sdc /dev/sdd"
BTRFS_RAID_LEVEL="raid10"
BCACHE_MODE="writeback"
```

### Minimal (2 users, 2 disks, no SSD)

```bash
USERS="admin user1"
NVME_DEVICE=""  # None
HDD_DEVICES="/dev/sdb /dev/sdc"
BTRFS_RAID_LEVEL="raid1"
BCACHE_MODE="none"
```

### Large (10 users, 6 disks)

```bash
USERS="u1 u2 u3 u4 u5 u6 u7 u8 u9 u10"
HDD_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg"
BTRFS_RAID_LEVEL="raid10"
MEMORY_GUARANTEE_GB=16  # Less RAM per user
MEMORY_LIMIT_GB=64
```

## Architecture

### Storage

```
1TB NVMe
├── 100GB OS (Ubuntu 24.04 LTS)
└── 900GB bcache (writeback mode)

4x 20TB HDDs
└── BTRFS RAID10 (~40TB usable)
    ├── with bcache acceleration
    ├── /homes (backed up to GDrive)
    ├── /workspaces (ephemeral, not backed up)
    └── /cache/gdrive (80% of storage for Google Drive cache)

Google Workspace Shared Drive
└── Mounted at /shared via rclone VFS
    ├── Local cache: ~25TB (80% of free space after user data + snapshots)
    ├── Near-local performance after first access
    └── Auto-sync with cloud (LRU eviction, 30-day max age)
```

### Containers

```
Infrastructure (Shared):
├── Traefik (reverse proxy)
├── Apache Guacamole + guacd (remote desktop gateway)
├── Kasm Workspaces (container streaming)
├── Netdata (monitoring)
├── Prometheus + Grafana (metrics)
└── FileBrowser, Dozzle, Portainer, TensorBoard

Per-User Workspaces (One container each):
├── workspace-alice
├── workspace-bob
├── workspace-charlie
├── workspace-dave
└── workspace-eve

Each workspace contains:
├── Full KDE Plasma desktop
├── TigerVNC server (for Guacamole/VNC clients)
├── XRDP server (for RDP clients)
├── noVNC websockify (HTML5 VNC in browser)
├── SSH server (for terminal access)
├── VS Code + PyCharm + Jupyter
├── Docker-in-Docker
└── All development tools
```

### Network Flow

```
Remote Users                     Local Users
     ↓                                ↓
Cloudflare Tunnel                Local DNS
     ↓                                ↓
Traefik (:80) ←───────────────────────┘
     ↓
Routes by hostname:
├── guacamole.domain.com → Guacamole Gateway
├── kasm.domain.com → Kasm Workspaces
├── alice-code.domain.com → Alice's VS Code
├── alice-jupyter.domain.com → Alice's Jupyter
├── alice-tensorboard.domain.com → Alice's TensorBoard
└── ...

Direct Protocol Access (via ports):
├── VNC (5900+): For Guacamole backend or direct VNC clients
├── RDP (3389+): For direct RDP clients (Windows Remote Desktop)
└── noVNC (6080+): HTML5 VNC in browser (no gateway needed)
```

## User Guide

### Understanding Your Environment: Container vs VM

Your workspace runs in a Docker container, not a traditional VM. Here's what you need to know:

**What This Means:**

- You have `sudo` access inside your container
- You can install packages with `apt`, but they're temporary
- System packages disappear when we rebuild containers (image updates)
- Your personal files in `/home` and `/workspace` are always safe

**Persistent Storage (Survives Container Rebuilds):**

- `/home/${USERNAME}` - Your home directory (backed up daily to GDrive)
    - Use for: Code, configs, dotfiles, papers, small datasets
    - Suggested size: ~100GB (part of 1000GB total quota)

- `/workspace` - Fast scratch space (NOT backed up)
    - Use for: Training data, model checkpoints, experiments, large datasets
    - Suggested size: ~800GB (part of 1000GB total quota)
    - Reproducible/re-downloadable data here if needed after system issues

- `/shared` - Google Drive Workspace Shared Drive (cached locally)
    - **Backed by:** Google Workspace Shared Drive (cloud storage)
    - **Performance:** Near-local speed after first access (aggressive caching)
    - **Access:** Read-write for all users (share files with team)
    - **Use for:** Common datasets, shared files, team resources, collaboration
    - **Cache:** Auto-calculated (typically 60-70% of total disk, ~24TB for 5 users)
    - **Allocation:** Uses 80% of space remaining after user data + snapshot reservations
    - **Syncing:** Automatic background sync with Google Drive
    - **TensorBoard:** Each user has `/shared/tensorboard/${USERNAME}` for training logs


**Your Total Quota: 1000GB**

- Combined across `/home/${USERNAME}` + `/workspace` + docker volumes
- Monitored daily with breakdown by directory
- Warning alert at 80% (800GB), critical alert when exceeded
- Flexible allocation between directories (no per-directory enforcement)

**Ephemeral Locations (Reset on Container Rebuild):**

- Everything else: `/tmp`, `/var`, system directories
- Global Python packages installed with `sudo pip3 install`
- System packages installed with `sudo apt-get install`

**Why Separate Home and Workspace?**

1. **Backup Efficiency:** Only back up what matters (code/configs), not multi-TB datasets
2. **Clear Mental Model:** Users know what's safe vs what needs re-downloading
3. **Cost Savings:** GDrive storage costs based on backed-up data
4. **Faster Restores:** Restoring 100GB of code is fast; restoring 5TB of checkpoints is slow

**Storage Best Practices:**

- Put your code in `~` (home), put your data in `/workspace`
- If the server dies, your code is safe. Your training checkpoints? Re-train or re-download
- Store final model weights in `~` after training completes

**Python Package Management:**

Always use virtual environments in your home directory:

```bash
# Good - persists across container rebuilds
cd ~/my-project
python3 -m venv venv
source venv/bin/activate
pip install torch transformers wandb

# Also good - use conda
conda create -n myproject python=3.11
conda activate myproject
pip install -r requirements.txt

# Bad - disappears on container rebuild
sudo pip3 install some-package  # Goes to /usr/local (ephemeral)
```

**Requesting System Packages:**

If you need a system library (like `libopencv-dev`, `postgresql-client`, etc.):

1. Message the admin (e.g., via Telegram/Slack)
2. Specify the exact package name
3. Admin will add it to the Dockerfile and rebuild your container
4. Your container will restart (save your work first!)
5. Package will be available to all users going forward

Example request: "Can we add `ffmpeg` and `libsndfile1-dev` to the base image? Need them for audio processing."

### Storage Strategy Summary

| Location            | Backed Up? | Persistent? | Speed         | Backend                       | Use For                       |
|---------------------|------------|-------------|---------------|-------------------------------|-------------------------------|
| `/home/${USER}`     | ✅ Daily    | ✅ Yes       | Fast          | Local BTRFS                   | Code, configs, venvs          |
| `/workspace`        | ❌ No       | ✅ Yes       | Fastest       | Local BTRFS                   | Training data, checkpoints    |
| `/shared`           | ✅ GDrive   | ✅ Yes       | Fast (cached) | Google Workspace Shared Drive | Common datasets, shared files |
| `/tmp`, system dirs | ❌ No       | ❌ No        | Fast          | Container tmpfs               | Truly temporary files         |

**Storage Allocation Example with 5 users & 10TB BTRFS:**

- **User data**: 5TB (5 users × 1000GB quota per user)
    - Each user gets 1000GB total across home + workspace + docker-volumes (combined, monitored)
- **Snapshots**: 2.5TB (50% of user data, auto-calculated based on 24h+7d+4w retention)
- **VFS cache**: 2TB (80% of remaining 2.5TB after user data + snapshots)
- **Safety buffer**: ~2TB (20% margin to prevent BTRFS performance degradation)

**Quota Enforcement:**

- **Monitoring**: Daily quota checks across all three directories (home + workspace + docker-volumes)
- **Alerts**: Warning at 80% usage, critical alert when quota exceeded
- **No hard limits**: Users can temporarily exceed quota (soft limit with monitoring)
- **Breakdown visibility**: Daily reports show usage per directory

## Admin Guide

### Adding System Packages (When Users Request Them)

When a user requests a new system package:

1. **Verify the package exists:**
   ```bash
   # On the host or in any container
   apt-cache search package-name
   ```

2. **Add to Dockerfile:**
   ```bash
   cd docker
   nano Dockerfile.user-workspace

   # Find the appropriate section and add the package
   # For example, in the DEVELOPMENT TOOLS section:
   RUN apt-get update && apt-get install -y \
       existing-package \
       new-package-requested \
       && rm -rf /var/lib/apt/lists/*
   ```

3. **Rebuild affected container(s):**
   ```bash
   cd docker
   # Option A: Rebuild just one user (less disruption)
   docker compose build workspace-alice
   docker compose up -d workspace-alice

   # Option B: Rebuild all users (for widely-needed packages)
   docker compose build
   docker compose up -d

   # Note: Containers will restart automatically
   ```

4. **Verify installation:**
   ```bash
   docker exec -it workspace-alice which new-package-name
   # or
   docker exec -it workspace-alice apt list --installed | grep new-package
   ```

5. **Notify users:**
    - Inform them the package is now available
    - Remind them to save work before container restarts

**Time estimate:** 5-10 minutes per package request

**Tip:** For Python packages, direct users to use `pip install` in their virtual environments instead. Only system
libraries (with `-dev` suffix, command-line tools, etc.) need Dockerfile changes.

## Maintenance

- **Daily**: Check Telegram alerts, review dashboards
- **Weekly**: Review logs, check disk usage
- **Monthly**: Verify backup restore (automated), BTRFS scrub
- **Quarterly**: Update Docker images, test failover

**For detailed maintenance procedures and automation schedules, see [SETUP-GUIDE.md#maintenance](SETUP-GUIDE.md#maintenance)**

## Troubleshooting

**Quick health checks:**

```bash
docker compose ps              # Check all containers
docker logs workspace-alice    # Check specific service
sudo btrfs filesystem df /mnt/storage  # Check storage
nvidia-smi                     # Check GPU
sudo systemctl status cloudflared      # Check tunnel
```

**For detailed troubleshooting, see [SETUP-GUIDE.md#troubleshooting](SETUP-GUIDE.md#troubleshooting)**

## Support

- Comprehensive documentation (4 guides, 8,000+ lines)
- Validation script catches errors before setup
- Automated testing suite
- Scripts with helpful error messages

## Project Stats

- **Files**: 70+ (scripts, configs, docs)
- **Code**: ~8,000 lines (Bash, Python, YAML, Markdown)
- **Setup Time**: 30-60 minutes
- **Break-even**: 1.5 months
- **5-Year Savings**: $240,000

