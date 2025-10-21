# Problem
5 trusted friends using GCP GCE (nn1-highmem-16 + Nvidia T4) for ML training, spending over $2000/mo. Customer sends 10GB data daily via GCS.
Main "source-of-truth" storage is 50TB GCS, costing us thousands just to have it stored, let alone egress.

# Goal
Replace GCP GCE with single on-premise PC for ML training only. Keep GCP for serving end-users.
Move main "source-of-truth" storage to GDrive Workspace.

# Hardware
CPU: Threadripper (already owned)
RAM: 200GB DDR5 (owned 64 GB, will be upgraded)
GPU: RTX 5080 (already owned)
Storage: 1TB NVMe (already owned) + 4x 20TB HDD
UPS: 1500VA
Location: Air-conditioned small head office, 300 Mbps connection

## Storage Architecture

1 TB NVMe
OS + Docker engine: 100GB
bcache: 900GB (writeback mode)

4x20TB BTRFS RAID10 relatime zstd:3 space_cache=v2 (skip autodefrag)

Usable capacity: ~40TB
User home folders: /mnt/storage/homes/
Docker volumes: /mnt/storage/docker-volumes/
Workspaces (ephemeral, not backed up): /mnt/storage/workspaces/
Shared data: /mnt/storage/shared/
Snapshots: /mnt/storage/snapshots/

# Software Configuration
OS: Ubuntu 24.04 LTS
Container Runtime: Docker + nvidia-container-toolkit

## Core Services

Traefik: Reverse proxy + routing (no rate limiting - handled by Cloudflare)
NoMachine: Per-user remote desktop access (NX protocol)
Netdata: health.mydomain.com (includes disk SMART monitoring)
Prometheus: prometheus.mydomain.com (scrapes nvidia-smi exporter, node exporter)
Grafana: grafana.mydomain.com (dashboards for GPU, disk, network, container resources)
code-server: alice-code.mydomain.com, bob-code.mydomain.com (VS Code in browser)
Shared TensorBoard: tensorboard.mydomain.com (users write logs to /mnt/storage/shared/tensorboard/)
FileBrowser: files.mydomain.com
Dozzle: logs.mydomain.com (7-day retention)
Portainer: portainer.mydomain.com
smartmontools: Automated disk health checks + alerts
Per-User Jupyter: alice-jupyter.mydomain.com, bob-jupyter.mydomain.com

## Authentication & Security

Each user has a regular Linux account (useradd alice, bob, charlie, dave, eve)
Passwords stored in /etc/shadow, SSH keys in ~/.ssh/authorized_keys, Users in docker and sudo groups

Cloudflare Tunnel: All traffic routed through Cloudflare (no ports exposed)
Cloudflare Access: Google Workspace login with 2FA enforcement (provides application-level authentication)
SSH: SSH key-based authentication only (no passwords, no additional 2FA since Cloudflare Access already enforces 2FA)
NoMachine: Password authentication (over Cloudflare Tunnel or local network)
Local users: All users in docker and sudo groups
UFW: Deny all incoming, allow all outgoing
fail2ban: Monitor auth logs for SSH brute force attempts
Automatic security updates: unattended-upgrades enabled

## User Container Design

UID/GID: Mapped to host users (1000-1004)
Desktop: KDE Plasma
Remote access: NoMachine (NX protocol on ports 4000-4004, web access via Traefik)
ML stack: PyTorch, TensorFlow, JAX, CUDA 12.4, cuDNN
Development tools: VS Code, PyCharm, Jupyter Lab, Python 3.11+, Git, Go, Rust, Julia, R
GUI apps: Firefox, Chromium, LibreOffice, GIMP, Inkscape, Konsole
Audio: PulseAudio
Docker-in-Docker: Run containers inside workspace

Volumes:
/mnt/storage/homes/${USER}:/home/${USER}:rw
/mnt/storage/workspaces/${USER}:/workspace:rw
/mnt/storage/shared:/shared:ro
/mnt/storage/shared/tensorboard/${USER}:/tensorboard:rw
/mnt/storage/docker-volumes/${USER}-state:/data:rw

## Resource Limits:

Memory: 32 GB guaranteed, 100 GB limit. Swap 50GB on NVMe per container as fallback
oom-kill-disable: false
CPU: cpuset-cpus per CCX
GPU: Shared access via time-slicing (manual coordination via Telegram)
Traefik: 50 average, 200 burst

No formal reservation system (RTX 5080 much faster than T4, conflicts unlikely)

Storage: User reminded at the end of day if their disk usage exceeds 1TB

## Data Pipeline

### GCS to GDrive Migration (One-time, then incremental)

Renting a second machine in GCP for the migration to avoid egress. Copy within GCP, then download via Google Takeout

### Daily Customer Data Ingestion (4 AM, 100 Mbps limit)

rclone copy gcs:customer-daily-bucket/ gdrive:customer-daily/ --bwlimit 100M

Post-migration (Month 12): Customer uploads directly to GDrive shared folder

## Backup Strategy

Tier 1: Local BTRFS Snapshots 24 hourly, 7 daily, 4 weekly
Tier 2: Restic to GDrive Workspace (Daily 6 AM, 100 Mbps) 7 daily, 52 weekly

Backed up:

User home folders: /mnt/storage/homes/
Docker volumes: /mnt/storage/docker-volumes/ (containers paused during backup)
Shared tensorboard: /mnt/storage/shared/tensorboard/

NOT backed up:

Workspaces: /mnt/storage/workspaces/ (ephemeral)
Customer data: Already in GDrive
Docker images: Reproducible from Dockerfiles
OS/packages: Reproducible from install scripts

Backup verification:

Monthly automated restore test to /tmp/restore-test/
Alert via healthchecks.io + Telegram if restore fails

BTRFS Monthly Scrub

### Long-term Strategy

Month 1-2: Stabilize on-premise setup, migrate 50TB GCS → GDrive
Month 3-6: Work from GDrive instead of GCS, customer still uploads to GCS
Month 6-11: Customer uploads to GDrive, keep GCS just-in-case
Month 12: Only serving/inference data in GCS

# Networking & Infrastructure

Domain & DNS: Cheap domain from Cloudflare Registrar (~$10/year), Cloudflare Tunnel routes *.mydomain.com to local Traefik
Internet Connection: 300 Mbps, 2 users remote max, 3 users in office

# Monitoring & Alerting:

## Metrics collected:

GPU utilization, memory, temperature (nvidia-smi exporter)
Disk I/O, health, SMART status (node exporter, smartmontools)
Container CPU, memory, network (cAdvisor)
Network bandwidth per interface (Netdata)
BTRFS filesystem health (custom script)
Per-user disk usage (custom script, daily check)

## Alerts sent to Telegram:

Disk SMART warnings/failures (critical)
GPU temperature >80°C (warning)
Container OOM kills (warning)
Backup job failures (critical)
Data sync job failures (critical)
Filesystem >90% full (warning)
User exceeds 1TB quota for >7 days (warning)
Multiple users using GPU simultaneously (info)

# Cost Analysis

## Monthly Savings:

Before: $2000+ GCE + $2000+ GCS
After: $150 electricity + $150 GDrive Workspace + $50 hardware replacement fund
Net savings: $3650+/month

## One time cost 

Assume needs to buy all new PC components: $5000
Break-even point: Under 1.5 months