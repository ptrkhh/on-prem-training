#!/bin/bash
set -euo pipefail

# ML Training Server - Shared Cache Setup
# Creates shared cache directories for ML models, packages, and dependencies
# This allows all users to benefit from cached downloads

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

# Load configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example and edit it."
    exit 1
fi

source "${CONFIG_FILE}"

echo "=== Shared Cache Setup ==="
echo ""
echo "This script will create shared cache directories for:"
echo "  1. ML Models (HuggingFace, PyTorch, TensorFlow)"
echo "  2. Python packages (pip wheels)"
echo "  3. Conda/Mamba packages"
echo "  4. APT system packages"
echo "  5. Git LFS objects"
echo "  6. Language-specific caches (Go, npm, Rust, Julia, R)"
echo "  7. Container build cache"
echo "  8. Browser cache"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

CACHE_ROOT="${MOUNT_POINT}/cache"

# Create cache directory structure
echo "=== Creating Cache Directories ==="
echo ""

# 1. ML Models & Datasets
echo "1. ML Models & Datasets caches..."
mkdir -p "${CACHE_ROOT}/ml-models/huggingface"
mkdir -p "${CACHE_ROOT}/ml-models/torch"
mkdir -p "${CACHE_ROOT}/ml-models/tensorflow-hub"
mkdir -p "${CACHE_ROOT}/ml-models/datasets"
chmod 777 "${CACHE_ROOT}/ml-models"
chmod 777 "${CACHE_ROOT}/ml-models/huggingface"
chmod 777 "${CACHE_ROOT}/ml-models/torch"
chmod 777 "${CACHE_ROOT}/ml-models/tensorflow-hub"
chmod 777 "${CACHE_ROOT}/ml-models/datasets"

# 2. Python Package Cache
echo "2. Python pip cache..."
mkdir -p "${CACHE_ROOT}/pip"
chmod 777 "${CACHE_ROOT}/pip"

# 3. Conda/Mamba Package Cache
echo "3. Conda package cache..."
mkdir -p "${CACHE_ROOT}/conda/pkgs"
mkdir -p "${CACHE_ROOT}/conda/envs"
chmod 777 "${CACHE_ROOT}/conda"
chmod 777 "${CACHE_ROOT}/conda/pkgs"
chmod 777 "${CACHE_ROOT}/conda/envs"

# 4. APT Package Cache
echo "4. APT package cache..."
mkdir -p "${CACHE_ROOT}/apt/archives/partial"
chmod 755 "${CACHE_ROOT}/apt"
chmod 755 "${CACHE_ROOT}/apt/archives"
chmod 755 "${CACHE_ROOT}/apt/archives/partial"

# 5. Git LFS Cache
echo "5. Git LFS cache..."
mkdir -p "${CACHE_ROOT}/git-lfs"
chmod 777 "${CACHE_ROOT}/git-lfs"

# 6. Language-Specific Caches
echo "6. Language-specific caches..."

# Go modules
mkdir -p "${CACHE_ROOT}/go/pkg/mod"
chmod 777 "${CACHE_ROOT}/go"
chmod 777 "${CACHE_ROOT}/go/pkg"
chmod 777 "${CACHE_ROOT}/go/pkg/mod"

# Node.js/npm
mkdir -p "${CACHE_ROOT}/npm"
chmod 777 "${CACHE_ROOT}/npm"

# Rust Cargo
mkdir -p "${CACHE_ROOT}/cargo/registry"
mkdir -p "${CACHE_ROOT}/cargo/git"
chmod 777 "${CACHE_ROOT}/cargo"
chmod 777 "${CACHE_ROOT}/cargo/registry"
chmod 777 "${CACHE_ROOT}/cargo/git"

# Julia
mkdir -p "${CACHE_ROOT}/julia/packages"
mkdir -p "${CACHE_ROOT}/julia/artifacts"
chmod 777 "${CACHE_ROOT}/julia"
chmod 777 "${CACHE_ROOT}/julia/packages"
chmod 777 "${CACHE_ROOT}/julia/artifacts"

# R packages
mkdir -p "${CACHE_ROOT}/R/packages"
chmod 777 "${CACHE_ROOT}/R"
chmod 777 "${CACHE_ROOT}/R/packages"

# 7. Container Build Cache
echo "7. Container build cache..."
mkdir -p "${CACHE_ROOT}/buildkit"
chmod 777 "${CACHE_ROOT}/buildkit"

# 8. Browser Cache
echo "8. Browser profile caches..."
mkdir -p "${CACHE_ROOT}/browser/firefox"
mkdir -p "${CACHE_ROOT}/browser/chromium"
chmod 777 "${CACHE_ROOT}/browser"
chmod 777 "${CACHE_ROOT}/browser/firefox"
chmod 777 "${CACHE_ROOT}/browser/chromium"

# 9. Google Drive VFS cache directory
# Note: This is created and managed by 01b-setup-gdrive-shared.sh
# We ensure it exists here for consistency, but don't recreate if already present
echo "9. Google Drive VFS cache..."
mkdir -p "${CACHE_ROOT}/gdrive"
chmod 755 "${CACHE_ROOT}/gdrive"

# 10. JetBrains IDE caches (PyCharm, IntelliJ, etc.)
echo "10. JetBrains IDE caches..."
mkdir -p "${CACHE_ROOT}/jetbrains/config"
mkdir -p "${CACHE_ROOT}/jetbrains/plugins"
mkdir -p "${CACHE_ROOT}/jetbrains/system"
chmod 777 "${CACHE_ROOT}/jetbrains"
chmod 777 "${CACHE_ROOT}/jetbrains/config"
chmod 777 "${CACHE_ROOT}/jetbrains/plugins"
chmod 777 "${CACHE_ROOT}/jetbrains/system"

# 11. Docker layer cache (for Docker-in-Docker)
echo "11. Docker layer cache..."
mkdir -p "${CACHE_ROOT}/docker-layers"
chmod 777 "${CACHE_ROOT}/docker-layers"

echo ""
echo "✅ Cache directories created"
echo ""

# Create cache info script
echo "=== Creating Cache Management Scripts ==="

mkdir -p /opt/scripts/cache

cat > /opt/scripts/cache/show-cache-info.sh <<'EOF'
#!/bin/bash
# Display cache usage statistics

CACHE_ROOT="${MOUNT_POINT:-/mnt/storage}/cache"

echo "=== Shared Cache Statistics ==="
echo ""
echo "Location: ${CACHE_ROOT}"
echo ""

if [[ ! -d "${CACHE_ROOT}" ]]; then
    echo "ERROR: Cache directory not found!"
    exit 1
fi

# Function to show directory size
show_size() {
    local dir=$1
    local desc=$2
    if [[ -d "${dir}" ]]; then
        local size=$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')
        local files=$(find "${dir}" -type f 2>/dev/null | wc -l)
        printf "%-30s %10s (%s files)\n" "${desc}" "${size}" "${files}"
    else
        printf "%-30s %10s\n" "${desc}" "N/A"
    fi
}

echo "ML Models & Datasets:"
show_size "${CACHE_ROOT}/ml-models/huggingface" "  HuggingFace Hub"
show_size "${CACHE_ROOT}/ml-models/torch" "  PyTorch Hub"
show_size "${CACHE_ROOT}/ml-models/tensorflow-hub" "  TensorFlow Hub"
show_size "${CACHE_ROOT}/ml-models/datasets" "  Datasets"
echo ""

echo "Package Caches:"
show_size "${CACHE_ROOT}/pip" "  pip (Python wheels)"
show_size "${CACHE_ROOT}/conda/pkgs" "  conda packages"
show_size "${CACHE_ROOT}/apt/archives" "  apt packages"
echo ""

echo "Language-Specific:"
show_size "${CACHE_ROOT}/go/pkg/mod" "  Go modules"
show_size "${CACHE_ROOT}/npm" "  npm packages"
show_size "${CACHE_ROOT}/cargo" "  Rust cargo"
show_size "${CACHE_ROOT}/julia" "  Julia packages"
show_size "${CACHE_ROOT}/R/packages" "  R packages"
echo ""

echo "Other Caches:"
show_size "${CACHE_ROOT}/git-lfs" "  Git LFS objects"
show_size "${CACHE_ROOT}/buildkit" "  BuildKit cache"
show_size "${CACHE_ROOT}/browser" "  Browser cache"
show_size "${CACHE_ROOT}/jetbrains" "  JetBrains IDEs"
show_size "${CACHE_ROOT}/docker-layers" "  Docker layers"
show_size "${CACHE_ROOT}/gdrive" "  Google Drive VFS"
echo ""

echo "Total Cache Usage:"
TOTAL_SIZE=$(du -sh "${CACHE_ROOT}" 2>/dev/null | awk '{print $1}')
echo "  ${TOTAL_SIZE}"
echo ""

# Show disk space
echo "Disk Space:"
df -h "${CACHE_ROOT}" | tail -n1
echo ""
EOF

chmod +x /opt/scripts/cache/show-cache-info.sh

# Create cache cleanup template (to be customized later)
cat > /opt/scripts/cache/clean-cache.sh.example <<'EOF'
#!/bin/bash
# Clean old cache entries (template - customize retention policies as needed)

CACHE_ROOT="${MOUNT_POINT:-/mnt/storage}/cache"

echo "=== Cache Cleanup ==="
echo ""
echo "This is a template script. Customize retention policies before running!"
echo ""
echo "Example cleanup commands:"
echo ""
echo "# Clean pip cache older than 90 days"
echo "find ${CACHE_ROOT}/pip -type f -mtime +90 -delete"
echo ""
echo "# Clean conda packages older than 60 days"
echo "find ${CACHE_ROOT}/conda/pkgs -type f -mtime +60 -delete"
echo ""
echo "# Clean APT cache older than 30 days"
echo "find ${CACHE_ROOT}/apt/archives -type f -mtime +30 -delete"
echo ""
echo "# Clean browser cache older than 14 days"
echo "find ${CACHE_ROOT}/browser -type f -mtime +14 -delete"
echo ""
echo "Note: ML model caches should typically not be auto-cleaned"
echo "      as they are large downloads that users may need long-term."
echo ""
EOF

chmod +x /opt/scripts/cache/clean-cache.sh.example

# Create environment file for cache paths
cat > /opt/cache-env.sh <<EOF
# Shared Cache Environment Variables
# Source this file in container startup scripts

# ML Models & Datasets
export HF_HOME=/cache/ml-models/huggingface
export TRANSFORMERS_CACHE=/cache/ml-models/huggingface
export HF_DATASETS_CACHE=/cache/ml-models/datasets
export TORCH_HOME=/cache/ml-models/torch
export TFHUB_CACHE_DIR=/cache/ml-models/tensorflow-hub

# Python packages
export PIP_CACHE_DIR=/cache/pip

# Conda packages
export CONDA_PKGS_DIRS=/cache/conda/pkgs

# Git LFS
export GIT_LFS_CACHE_DIR=/cache/git-lfs

# Language-specific caches
export GOMODCACHE=/cache/go/pkg/mod
export npm_config_cache=/cache/npm
export CARGO_HOME=/cache/cargo
export JULIA_DEPOT_PATH=/cache/julia
export R_LIBS_USER=/cache/R/packages

# Container build cache
export BUILDKIT_CACHE=/cache/buildkit
EOF

chmod 644 /opt/cache-env.sh

echo ""
echo "✅ Cache management scripts created:"
echo "   - /opt/scripts/cache/show-cache-info.sh"
echo "   - /opt/scripts/cache/clean-cache.sh (template)"
echo "   - /opt/cache-env.sh (environment variables)"
echo ""

# Create README
cat > "${CACHE_ROOT}/README.md" <<'EOF'
# Shared Cache Directory

This directory contains shared caches for all users to improve performance and reduce redundant downloads.

## Structure

```
/cache/
├── ml-models/          # ML model weights and datasets
│   ├── huggingface/    # HuggingFace Hub models
│   ├── torch/          # PyTorch Hub models
│   ├── tensorflow-hub/ # TensorFlow Hub models
│   └── datasets/       # HuggingFace datasets
├── pip/                # Python package wheels
├── conda/              # Conda packages
│   ├── pkgs/           # Package cache
│   └── envs/           # Shared environments (optional)
├── apt/                # APT package cache
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

## Usage

Cache directories are automatically mounted in user containers and environment variables are set.

### Check cache usage:
```bash
/opt/scripts/cache/show-cache-info.sh
```

### Environment variables:
All cache paths are configured via environment variables in containers.
See `/opt/cache-env.sh` for the complete list.

## Benefits

- **Faster model downloads**: First user downloads, others use cached copy
- **Reduced bandwidth**: No redundant downloads across users
- **Faster pip installs**: Pre-built wheels cached locally
- **Faster container builds**: Shared build cache across users

## Examples

### Python - HuggingFace Model
```python
from transformers import AutoModel

# First user: Downloads ~500MB model from internet
model = AutoModel.from_pretrained("bert-base-uncased")

# Other users: Instant load from /cache/ml-models/huggingface
```

### Python - pip install
```bash
# First user: Downloads wheels
pip install torch transformers numpy

# Other users: Uses cached wheels (10-50x faster)
```

## Maintenance

Cache cleanup policies will be implemented later based on usage patterns.
For now, caches will grow indefinitely (monitor with show-cache-info.sh).
EOF

chmod 644 "${CACHE_ROOT}/README.md"

echo "✅ Documentation created: ${CACHE_ROOT}/README.md"
echo ""

# Summary
echo "=== Shared Cache Setup Complete ==="
echo ""
echo "Cache directories created:"
echo "  1. ML Models: ${CACHE_ROOT}/ml-models/"
echo "  2. pip cache: ${CACHE_ROOT}/pip/"
echo "  3. conda cache: ${CACHE_ROOT}/conda/"
echo "  4. APT cache: ${CACHE_ROOT}/apt/"
echo "  5. Git LFS: ${CACHE_ROOT}/git-lfs/"
echo "  6. Go modules: ${CACHE_ROOT}/go/"
echo "  7. npm cache: ${CACHE_ROOT}/npm/"
echo "  8. Rust cargo: ${CACHE_ROOT}/cargo/"
echo "  9. Julia: ${CACHE_ROOT}/julia/"
echo " 10. R packages: ${CACHE_ROOT}/R/"
echo " 11. BuildKit: ${CACHE_ROOT}/buildkit/"
echo " 12. Browser: ${CACHE_ROOT}/browser/"
echo " 13. JetBrains IDEs: ${CACHE_ROOT}/jetbrains/"
echo " 14. Docker layers: ${CACHE_ROOT}/docker-layers/"
echo " 15. Google Drive VFS: ${CACHE_ROOT}/gdrive/ (existing)"
echo ""
echo "Management scripts:"
echo "  - View usage: /opt/scripts/cache/show-cache-info.sh"
echo "  - Cleanup: /opt/scripts/cache/clean-cache.sh (customize first)"
echo ""
echo "Next steps:"
echo "  1. Update Dockerfile to use cache environment variables"
echo "  2. Update docker-compose.yml to mount cache directories"
echo "  3. Rebuild containers to enable shared caches"
echo ""
echo "Note: These caches will benefit all users by eliminating redundant downloads"
echo "      and speeding up package installations, model downloads, and builds."
echo ""
