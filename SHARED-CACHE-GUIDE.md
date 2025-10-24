# Shared Cache System Guide

## Overview

The ML Training Server implements a comprehensive shared cache system where all users benefit from cached downloads. When one user downloads a package, model, or dependency, it's cached locally so other users can instantly access it.

## Architecture

```
/mnt/storage/cache/
├── ml-models/          # ML model weights and datasets
│   ├── huggingface/    # HuggingFace Hub models (transformers, datasets)
│   ├── torch/          # PyTorch Hub models
│   ├── tensorflow-hub/ # TensorFlow Hub models
│   └── datasets/       # HuggingFace datasets
├── pip/                # Python package wheels
├── conda/              # Conda packages
│   ├── pkgs/           # Package cache
│   └── envs/           # Shared environments (optional)
├── apt/                # APT .deb package cache
├── git-lfs/            # Git LFS objects
├── go/                 # Go modules
├── npm/                # Node.js packages
├── cargo/              # Rust packages
├── julia/              # Julia packages
├── R/                  # R packages
├── buildkit/           # Container build cache
├── browser/            # Browser profile caches
├── jetbrains/          # JetBrains IDE caches (PyCharm, etc.)
├── docker-layers/      # Docker layer cache (for Docker-in-Docker)
└── gdrive/             # Google Drive VFS cache
```

## How It Works

### 1. Container Mounts
All cache directories are mounted into user containers via docker-compose:
```yaml
volumes:
  - /mnt/storage/cache/ml-models:/cache/ml-models:rw
  - /mnt/storage/cache/pip:/cache/pip:rw
  - /mnt/storage/cache/apt:/var/cache/apt:rw
  # ... etc for all cache types
```

### 2. Environment Variables
Cache paths are configured via environment variables in the Dockerfile:
```bash
# ML Models
export HF_HOME=/cache/ml-models/huggingface
export TORCH_HOME=/cache/ml-models/torch
export TFHUB_CACHE_DIR=/cache/ml-models/tensorflow-hub

# Python packages
export PIP_CACHE_DIR=/cache/pip

# Language-specific
export GOMODCACHE=/cache/go/pkg/mod
export npm_config_cache=/cache/npm
export CARGO_HOME=/cache/cargo
```

### 3. APT Package Caching
APT is configured to keep downloaded .deb files:
```bash
# In Dockerfile
RUN echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
```

## Real-World Examples

### Example 1: Loading HuggingFace Models

**First User (Alice):**
```python
from transformers import AutoModel

# Downloads ~500MB from internet
model = AutoModel.from_pretrained("bert-base-uncased")
# Downloaded to: /cache/ml-models/huggingface/models--bert-base-uncased/
```

**Second User (Bob):**
```python
from transformers import AutoModel

# Instant load from cache (no download)
model = AutoModel.from_pretrained("bert-base-uncased")
# Loaded from: /cache/ml-models/huggingface/models--bert-base-uncased/
```

**Impact:** 500MB download → Instant access for all users

---

### Example 2: Installing Python Packages

**First User (Alice):**
```bash
pip install torch transformers numpy pandas
# Downloads ~2GB of wheels from PyPI
# Cached to: /cache/pip/
```

**Second User (Bob):**
```bash
pip install torch transformers numpy pandas
# Installs from cache (10-50x faster)
# No internet download needed
```

**Impact:** 2GB download + 5 min install → 200MB + 10 sec install

---

### Example 3: APT Package Installation

**First User (Alice) - In container:**
```bash
sudo apt-get update
sudo apt-get install ffmpeg libopencv-dev
# Downloads ~150MB of .deb packages
# Cached to: /var/cache/apt/archives/ (mounted from /cache/apt/)
```

**Second User (Bob) - In container:**
```bash
sudo apt-get update
sudo apt-get install ffmpeg libopencv-dev
# Installs from cache (near-instant)
```

**Impact:** 150MB download → Instant install from cache

---

### Example 4: Docker Build with Cache

**Building user workspace for first time:**
```bash
docker compose build workspace-alice
# Downloads PyTorch, TensorFlow, system packages
# Build time: 30-45 minutes
# Downloaded: ~8GB
```

**Rebuilding or building for another user:**
```bash
docker compose build workspace-bob
# Uses cached layers and APT packages
# Build time: 2-5 minutes
# Downloaded: ~500MB (only new/changed packages)
```

**Impact:** 8GB + 45 min → 500MB + 3 min

---

## Cache Benefits by Category

| Cache Type | Typical Size | First Access | Cached Access | Bandwidth Saved |
|------------|--------------|--------------|---------------|-----------------|
| ML Models (BERT) | 500MB | 30-60 sec | Instant | 500MB per user |
| PyTorch install | 2GB | 3-5 min | 10-30 sec | 2GB per user |
| APT packages | 500MB-2GB | 5-10 min | 30 sec | 500MB+ per user |
| npm packages | 100MB-500MB | 2-5 min | 10-20 sec | 100MB+ per user |
| Docker layers | 5GB-10GB | 30-45 min | 2-5 min | 8GB per rebuild |

**Total savings for 5 users:** 15-40GB bandwidth, 2-4 hours of waiting time

---

## Monitoring Cache Usage

### View cache statistics:
```bash
/opt/scripts/cache/show-cache-info.sh
```

Output:
```
=== Shared Cache Statistics ===

ML Models & Datasets:
  HuggingFace Hub              2.5G (47 files)
  PyTorch Hub                  1.2G (12 files)
  TensorFlow Hub               800M (8 files)
  Datasets                     3.1G (23 files)

Package Caches:
  pip (Python wheels)          4.2G (1847 files)
  conda packages               2.8G (234 files)
  apt packages                 1.5G (892 files)

Language-Specific:
  Go modules                   500M (1234 files)
  npm packages                 1.2G (3421 files)
  Rust cargo                   800M (567 files)

Other Caches:
  Git LFS objects              2.3G (45 files)
  BuildKit cache               3.5G (N/A)
  JetBrains IDEs               1.1G (2341 files)
  Docker layers                8.2G (N/A)

Total Cache Usage: 33.8GB
```

### Monitor disk space:
```bash
df -h /mnt/storage
```

---

## Cache Management

### Automatic Management
- **Google Drive VFS cache:** Auto-evicts via LRU (configured max size + max age)
- **Docker BuildKit:** Auto-prunes old layers (configurable)
- **pip/conda:** Grows indefinitely (manual cleanup recommended)

### Manual Cleanup

**Option 1: Clean specific cache:**
```bash
# Clean old pip cache (90+ days)
find /mnt/storage/cache/pip -type f -mtime +90 -delete

# Clean conda packages (60+ days)
find /mnt/storage/cache/conda/pkgs -type f -mtime +60 -delete

# Clean APT cache (30+ days)
find /mnt/storage/cache/apt/archives -type f -mtime +30 -delete
```

**Option 2: Use cleanup script template:**
```bash
# Edit retention policies first
nano /opt/scripts/cache/clean-cache.sh

# Run cleanup
sudo /opt/scripts/cache/clean-cache.sh
```

**Important:** Do NOT auto-clean ML model caches - they are large downloads users may need long-term.

---

## Best Practices

### For Users

1. **First-time model downloads:** Be patient - you're caching for everyone
2. **Check before downloading:** Model might already be cached
3. **Use virtual environments:** Keeps package management clean
4. **Report popular models:** Ask admin to pre-cache common models

### For Admins

1. **Pre-populate common models:**
```bash
# As root on host
cd /mnt/storage/cache/ml-models/huggingface
docker exec -it workspace-alice python3 -c "
from transformers import AutoModel
AutoModel.from_pretrained('bert-base-uncased')
AutoModel.from_pretrained('gpt2')
AutoModel.from_pretrained('t5-base')
"
```

2. **Monitor cache growth:**
```bash
# Add to weekly cron
/opt/scripts/cache/show-cache-info.sh
```

3. **Set retention policies:**
```bash
# Clean caches older than 90 days (except ML models)
# Add to monthly cron
find /cache/{pip,conda,apt,npm,cargo} -mtime +90 -delete
```

4. **Reserve enough disk space:**
- Estimate: 50-100GB for ML models
- Estimate: 20-40GB for pip/conda
- Estimate: 10-20GB for system packages
- Estimate: 10-30GB for Docker layers
- **Total: 90-190GB recommended minimum**

---

## Troubleshooting

### Cache not being used

**Check mounts:**
```bash
docker exec -it workspace-alice df -h | grep cache
```

Should show:
```
/dev/mapper/...  /cache/ml-models  ...
/dev/mapper/...  /cache/pip        ...
```

**Check environment variables:**
```bash
docker exec -it workspace-alice env | grep CACHE
docker exec -it workspace-alice env | grep HF_HOME
```

Should show:
```
PIP_CACHE_DIR=/cache/pip
HF_HOME=/cache/ml-models/huggingface
```

---

### Permission errors

**Fix cache permissions:**
```bash
sudo chmod -R 777 /mnt/storage/cache/ml-models
sudo chmod -R 777 /mnt/storage/cache/pip
sudo chmod -R 777 /mnt/storage/cache/conda
# ... etc for other caches
```

**Or re-run setup:**
```bash
sudo ./scripts/01c-setup-shared-caches.sh
```

---

### Cache filling up disk

**Check cache sizes:**
```bash
du -sh /mnt/storage/cache/*
```

**Clean selectively:**
```bash
# Find largest cached items
du -sh /mnt/storage/cache/*/* | sort -h | tail -20

# Remove specific large items
rm -rf /mnt/storage/cache/ml-models/huggingface/models--some-huge-model
```

---

## Configuration Reference

### Cache locations (in containers):
- `/cache/ml-models/` - ML models and datasets
- `/cache/pip/` - Python pip wheels
- `/cache/conda/` - Conda packages
- `/var/cache/apt/` - APT packages
- `/cache/go/` - Go modules
- `/cache/npm/` - Node.js packages
- `/cache/cargo/` - Rust packages
- `/cache/julia/` - Julia packages
- `/cache/R/` - R packages
- `/cache/git-lfs/` - Git LFS objects
- `/cache/jetbrains/` - JetBrains IDE caches
- `/cache/buildkit/` - Container build cache
- `/cache/browser/` - Browser profiles

### Environment variables:
See `docker/Dockerfile.user-workspace` lines 285-320 for complete list.

---

## Impact Summary

**Bandwidth Savings:**
- 5 users installing same ML stack: 40GB → 8GB (80% reduction)
- 5 users loading same models: 2.5GB → 500MB (80% reduction)

**Time Savings:**
- pip install (cached): 5 min → 30 sec (10x faster)
- Docker rebuild (cached): 45 min → 3 min (15x faster)
- Model loading (cached): 1 min → instant (100x faster)

**Storage Efficiency:**
- Without cache: 5 users × 10GB each = 50GB duplicated data
- With cache: 10GB shared + 5GB unique = 15GB total (70% savings)

---

## Support

For issues or questions:
1. Check `/var/log/docker/` for container logs
2. Run `/opt/scripts/cache/show-cache-info.sh` to verify setup
3. Review this guide's troubleshooting section
4. Check Docker mounts: `docker inspect workspace-<username>`
