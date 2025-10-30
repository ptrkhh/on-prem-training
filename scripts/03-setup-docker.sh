#!/bin/bash
set -euo pipefail

# ML Training Server - Docker and NVIDIA Container Toolkit Setup

echo "=== Docker and NVIDIA Container Toolkit Setup ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example"
    exit 1
fi

source "${CONFIG_FILE}"

# Input validation helper function
validate_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -p "${prompt} (y/n): " response
        case "${response}" in
            y|Y|yes|Yes|YES) return 0;;
            n|N|no|No|NO) return 1;;
            *) echo "Please answer y or n";;
        esac
    done
}

validate_yes_no_full() {
    local prompt="$1"
    local response
    while true; do
        read -p "${prompt} (yes/no): " response
        case "${response}" in
            yes|Yes|YES) return 0;;
            no|No|NO) return 1;;
            *) echo "Please answer yes or no";;
        esac
    done
}

# Step 1: Install Docker
echo ""
echo "=== Step 1: Installing Docker ==="

# Remove old versions
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Install dependencies
apt update
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Docker installed successfully"

# Step 2: Install NVIDIA Drivers
echo ""
echo "=== Step 2: Installing NVIDIA Drivers ==="

# Check if nvidia-smi already works
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA drivers already installed:"
    nvidia-smi
else
    # Install NVIDIA drivers
    apt update
    apt install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall

    echo "NVIDIA drivers installed. Reboot required."
    if validate_yes_no "Reboot now?"; then
        reboot
    else
        echo "Please reboot manually before continuing."
        exit 0
    fi
fi

# Verify nvidia-smi is working before proceeding
echo ""
echo "Verifying GPU access..."
if ! nvidia-smi &>/dev/null; then
    echo "ERROR: nvidia-smi is not working!"
    echo "NVIDIA drivers may not be properly installed or system needs a reboot."
    echo "Please ensure:"
    echo "  1. System has been rebooted after driver installation"
    echo "  2. NVIDIA GPU is properly connected"
    echo "  3. Drivers are compatible with your GPU"
    exit 1
fi
echo "✓ GPU detected successfully:"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

# Step 3: Install NVIDIA Container Toolkit
echo ""
echo "=== Step 3: Installing NVIDIA Container Toolkit ==="

# Add NVIDIA Container Toolkit repository
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Install nvidia-container-toolkit
apt update
apt install -y nvidia-container-toolkit

# Configure Docker to use NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo "NVIDIA Container Toolkit installed"

# Step 4: Configure Docker Daemon
echo ""
echo "=== Step 4: Configuring Docker Daemon ==="

# Configure Docker to store data on BTRFS storage
mkdir -p ${MOUNT_POINT}/docker

# Backup existing daemon.json if present
if [[ -f /etc/docker/daemon.json ]]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)
    echo "Backed up existing daemon.json"
fi

# Create Docker daemon config
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${MOUNT_POINT}/docker",
  "storage-driver": "${DOCKER_STORAGE_DRIVER}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILES}"
  },
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF

# Restart Docker
systemctl restart docker
systemctl enable docker

echo "Docker daemon configured"

# Step 5: Test Installation
echo ""
echo "=== Step 5: Testing Installation ==="

# Test Docker
echo "Testing Docker..."
docker run --rm hello-world

# Test NVIDIA runtime
echo ""
echo "Testing NVIDIA runtime..."
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi

# Step 6: Configure GPU time-slicing (optional)
echo ""
if validate_yes_no "Configure GPU time-slicing for shared access?"; then
    echo "Configuring GPU time-slicing..."

    # Create time-slicing config
    cat > /etc/nvidia-container-runtime/config.toml <<'EOF'
[nvidia-container-cli]
no-cgroups = false

[nvidia-container-runtime]
debug = "/var/log/nvidia-container-runtime.log"

[nvidia-container-runtime.modes.cdi]
annotation-prefixes = ["cdi.k8s.io/"]
spec-dirs = ["/etc/cdi", "/var/run/cdi"]
EOF

    # Note: Time-slicing is primarily handled by manual coordination via Telegram
    # No formal reservation system needed due to RTX 5080 being much faster than T4

    echo "GPU time-slicing config created (manual coordination via Telegram)"
fi

# Display summary
echo ""
echo "=== Docker Setup Complete ==="
echo ""
echo "Docker version:"
docker --version
docker compose version
echo ""
echo "NVIDIA Driver:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
echo ""
echo "Test GPU in container:"
docker run --rm --gpus all nvidia/cuda:latest nvidia-smi
echo ""
echo "Next steps:"
echo "  1. Verify Docker is working: docker run hello-world"
echo "  2. Verify GPU access: docker run --rm --gpus all nvidia/cuda:latest nvidia-smi"
echo "  3. Deploy services: cd docker && docker compose up -d"
echo ""
