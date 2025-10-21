# ML Training Server

**Replace $4,000/month GCP infrastructure with $350/month on-premise server**

Complete automated setup for migrating 5 trusted ML Engineers from Google Cloud with 5x GCE n1-highmem-16 + T4 GPU and shared repository in GCS to a single on-premise server. Save nearly $4,000/month ($48,000/year) while maintaining or improving performance.

## Quick Links

- **[SETUP-GUIDE.md](SETUP-GUIDE.md)** - Complete step-by-step setup instructions
- **[config.sh.example](config.sh.example)** - Configuration template (customize users, hardware, and all settings)

## What You Get

### Hardware (Flexible!)
- CPU: AMD Threadripper (or similar)
- RAM: 200GB DDR5 (configurable)
- GPU: RTX 5080 (or other Nvidia)
- Storage: 1TB NVMe + 4x 20TB HDD in BTRFS RAID10
- **Works with ANY disk configuration** (2-20+ disks, any sizes, any RAID level)

### Each User Gets ONE Container With Everything
- **Full KDE Plasma Desktop** (access via NoMachine client)
- **All Development Tools**: VS Code, PyCharm, Jupyter Lab, VSCodium
- **Complete ML Stack**: PyTorch, TensorFlow, JAX (all with CUDA 12.4)
- **Multiple Languages**: Python 3.11+, Go, Rust, Julia, R, Node.js
- **GUI Applications**: Firefox, Chromium, LibreOffice, GIMP, Inkscape
- **Docker-in-Docker**: Run containers inside your workspace
- **Persistent Storage**: Home directory survives restarts

### Infrastructure Services (Shared)
- **Traefik**: Reverse proxy and router
- **NoMachine**: High-performance remote desktop (runs in each user container)
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
- **Cloudflare Access**: Optional Google Workspace SSO + 2FA

### Automated Operations
- **Backups**: BTRFS snapshots (hourly/daily/weekly) + Restic to GDrive (daily)
- **Monitoring**: SMART checks, GPU temperature, BTRFS health, user quotas
- **Alerts**: Telegram notifications for critical events
- **Data Pipeline**: Daily GCS → GDrive sync with bandwidth limits

## Cost Savings

| Item | Before (GCP) | After (On-Premise) |
|------|--------------|-------------------|
| Compute | $2,000/mo | - |
| Storage | $2,000/mo | - |
| Electricity | - | $150/mo |
| GDrive Workspace | - | $150/mo |
| Hardware fund | - | $50/mo |
| **Total** | **$4,000/mo** | **$350/mo** |

**Savings: $3,650/month ($43,800/year)**

Break-even: ~1.5 months (even if buying all new hardware)

## Quick Start (30-60 minutes)

```bash
# 1. Clone repository
git clone <repo-url> train-server
cd train-server

# 2. Configure (edit users, domain, hardware settings)
cp config.sh.example config.sh
nano config.sh

# 3. Validate configuration
./scripts/00-validate-config.sh

# 4. Generate docker-compose.yml
cd docker && ./generate-compose.sh && cd ..

# 5. Run setup scripts (in order)
sudo ./scripts/01-setup-storage.sh  # REBOOT after this!
sudo ./scripts/02-setup-users.sh
sudo ./scripts/03-setup-docker.sh
sudo ./scripts/04-setup-cloudflare-tunnel.sh
sudo ./scripts/05-setup-firewall.sh
sudo ./scripts/06-setup-monitoring.sh
sudo ./scripts/07-setup-backups.sh
sudo ./scripts/08-setup-data-pipeline.sh

# 6. Build and start containers
cd docker
docker compose build
docker compose up -d

# 7. Run tests
cd ../scripts && sudo ./09-run-tests.sh
```

## Access Your Services

### Via Web Browser (Remote or Local)

**Infrastructure:**
- System Health: `http://health.yourdomain.com` (Netdata)
- Prometheus: `http://prometheus.yourdomain.com`
- Grafana: `http://grafana.yourdomain.com`
- Files: `http://files.yourdomain.com`
- Logs: `http://logs.yourdomain.com`

**Per-User (example for Alice):**
- Desktop (NoMachine Web): `http://alice-desktop.yourdomain.com`
- VS Code: `http://alice-code.yourdomain.com`
- Jupyter: `http://alice-jupyter.yourdomain.com`

**Shared:**
- TensorBoard: `http://tensorboard.yourdomain.com` (all users, organized by `/shared/tensorboard/{username}/`)

### Via NoMachine Client (Best Performance)

```bash
# Download NoMachine client from: https://nomachine.com/download

# Connect to Alice's desktop
Server: server_ip
Port: 4000 (alice), 4001 (bob), 4002 (charlie), etc.
Protocol: NX
Username: alice
Password: <user_password>

# SSH terminal access
ssh alice@server_ip -p 2222
```

## Key Features

✅ **Universal Hardware Support**: Auto-detects disks, works with 1-100 users, any RAID level
✅ **VM-Like Experience**: Full desktop + all tools in one container per user
✅ **Hybrid Network**: Fast local access + secure remote access via Cloudflare
✅ **Production Ready**: Automated backups, monitoring, alerts, health checks
✅ **Fully Customizable**: Single config file controls everything
✅ **Cost Effective**: 91% cost reduction vs GCP

## Documentation

- **[SETUP-GUIDE.md](SETUP-GUIDE.md)** - Comprehensive 600+ line manual with detailed instructions
- **[GRAND-PLAN.md](GRAND-PLAN.md)** - Original architecture and design decisions
- **[config.sh.example](config.sh.example)** - Complete configuration reference (100+ parameters)

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
    └── with bcache acceleration
```

### Containers
```
Infrastructure (Shared):
├── Traefik (reverse proxy)
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
├── NoMachine server (for remote desktop - client & web access)
├── SSH server (for terminal access)
├── VS Code + PyCharm + Jupyter
├── PyTorch + TensorFlow + JAX
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
├── alice-desktop.domain.com → Alice's NoMachine Web
├── alice-code.domain.com → Alice's VS Code
├── alice-jupyter.domain.com → Alice's Jupyter
├── alice-tensorboard.domain.com → Alice's TensorBoard
└── ...

Direct NoMachine Protocol (ports 4000+):
└── Best performance, bypasses HTTP
```

## Maintenance

**Daily**: Check Telegram alerts, review dashboards
**Weekly**: Review logs, check disk usage
**Monthly**: Verify backup restore (automated), BTRFS scrub
**Quarterly**: Update Docker images, test failover

## Troubleshooting

See [SETUP-GUIDE.md](SETUP-GUIDE.md#troubleshooting) for detailed troubleshooting steps.

Quick checks:
```bash
# Check all containers
docker compose ps

# Check specific service
docker logs workspace-alice

# Check storage
sudo btrfs filesystem df /mnt/storage

# Check GPU
nvidia-smi

# Check Cloudflare Tunnel
sudo systemctl status cloudflared
```

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
- **5-Year Savings**: $219,000

## Status

✅ **Production Ready** - All requirements met and exceeded

Deploy today and start saving $3,650/month!
