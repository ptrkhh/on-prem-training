#!/bin/bash
set -euo pipefail

# ML Training Server - Deploy Services

echo "=== Docker Services Deployment ==="

# Load common library and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Check if running as root
require_root

# Load configuration
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example"
    exit 1
fi

source "${CONFIG_FILE}"

# Set consistent project name to avoid network conflicts
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-on-prem-training}"

# Step 1: Verify Prerequisites
echo ""
echo "=== Step 1: Verifying Prerequisites ==="

# Check Docker is installed
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed"
    echo "Please run ./05-setup-docker.sh first"
    exit 1
fi

# Check Docker Compose is available
if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose is not available"
    echo "Please run ./05-setup-docker.sh first"
    exit 1
fi

# Check Docker daemon is running
if ! docker info &> /dev/null; then
    echo "ERROR: Docker daemon is not running"
    echo "Please start Docker: systemctl start docker"
    exit 1
fi

echo "✓ Docker is installed and running"
docker --version
docker compose version

# Check NVIDIA runtime is working
echo ""
echo "Checking NVIDIA runtime..."
if ! docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    echo "ERROR: NVIDIA runtime is not working"
    echo "Please verify Docker configuration and run ./05-setup-docker.sh"
    exit 1
fi
echo "✓ NVIDIA runtime is working"

# Step 2: Navigate to docker directory
echo ""
echo "=== Step 2: Preparing Docker Compose Environment ==="

DOCKER_DIR="${SCRIPT_DIR}/../docker"
if [[ ! -d "${DOCKER_DIR}" ]]; then
    echo "ERROR: Docker directory not found: ${DOCKER_DIR}"
    exit 1
fi

cd "${DOCKER_DIR}"
echo "✓ Changed to docker directory: ${DOCKER_DIR}"

# Generate docker-compose.yml if it doesn't exist or if generate script exists
if [[ -f "generate-compose.sh" ]]; then
    echo ""
    echo "Generating docker-compose.yml..."
    if ! ./generate-compose.sh; then
        echo "ERROR: Failed to generate docker-compose.yml"
        echo "Please check the error messages above"
        exit 1
    fi
    echo "✓ Generated docker-compose.yml"
elif [[ ! -f "docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml not found and no generate-compose.sh script available"
    exit 1
else
    echo "✓ Found docker-compose.yml"
fi

# Generate or check .env file
if [[ -f "generate-env.sh" ]]; then
    echo ""
    echo "Generating .env file..."
    if ! ./generate-env.sh; then
        echo "ERROR: Failed to generate .env file"
        echo "Please check the error messages above"
        exit 1
    fi
    echo "✓ Generated .env file"
elif [[ ! -f ".env" ]]; then
    if [[ -f ".env.example" ]]; then
        echo ""
        echo "Creating .env from .env.example..."
        cp .env.example .env
        echo "⚠️  Please review and update .env with your configuration"
        echo "After updating .env, run this script again"
        exit 1
    else
        echo "ERROR: Neither .env nor .env.example found, and no generate-env.sh script available"
        exit 1
    fi
else
    echo "✓ Found .env file"
fi

# Step 3: Pull Docker Images
echo ""
echo "=== Step 3: Pulling Docker Images ==="
echo "This may take several minutes..."

if ! docker compose pull; then
    echo "WARNING: Some images failed to pull"
    echo "This is normal if you're using custom images that need to be built"
fi

# Step 4: Deploy Services
echo ""
echo "=== Step 4: Deploying Services ==="

echo "Starting all services with Docker Compose..."
docker compose up -d

echo ""
echo "Waiting for services to initialize (10 seconds)..."
sleep 10

# Step 5: Verify Services
echo ""
echo "=== Step 5: Verifying Service Status ==="

# List all containers
echo ""
echo "Container Status:"
docker compose ps

# Check for unhealthy containers
UNHEALTHY=$(docker compose ps --format json | jq -r 'select(.Health == "unhealthy") | .Name' 2>/dev/null || true)
if [[ -n "${UNHEALTHY}" ]]; then
    echo ""
    echo "⚠️  WARNING: Some containers are unhealthy:"
    echo "${UNHEALTHY}"
    echo ""
    echo "Check logs with: docker compose logs <service-name>"
fi

# Check for stopped containers
STOPPED=$(docker compose ps --format json | jq -r 'select(.State != "running") | .Name' 2>/dev/null || true)
if [[ -n "${STOPPED}" ]]; then
    echo ""
    echo "⚠️  WARNING: Some containers are not running:"
    echo "${STOPPED}"
    echo ""
    echo "Check logs with: docker compose logs <service-name>"
fi

# Step 6: Display Service URLs
echo ""
echo "=== Services Deployed Successfully ==="
echo ""
echo "Infrastructure Services:"
echo "  - Traefik Dashboard: http://localhost:8080"
echo "  - Netdata: http://health.${DOMAIN:-localhost}"
echo "  - Prometheus: http://prometheus.${DOMAIN:-localhost}"
echo "  - Grafana: http://grafana.${DOMAIN:-localhost}"
echo "  - FileBrowser: http://files.${DOMAIN:-localhost}"
echo "  - Dozzle (logs): http://logs.${DOMAIN:-localhost}"
echo "  - Portainer: http://portainer.${DOMAIN:-localhost}"
echo "  - TensorBoard: http://tensorboard.${DOMAIN:-localhost}"
echo ""
echo "Per-User Workspaces:"
echo "  Access via hostnames configured in docker-compose.yml"
echo "  Example: http://alice.${DOMAIN:-localhost}"
echo ""
echo "Useful Commands:"
echo "  - View all services: docker compose ps"
echo "  - View logs: docker compose logs -f [service-name]"
echo "  - Restart service: docker compose restart [service-name]"
echo "  - Stop all: docker compose down"
echo "  - Start all: docker compose up -d"
echo ""
echo "Next steps:"
echo "  1. Setup Cloudflare Tunnel: sudo ./07-setup-cloudflare-tunnel.sh"
echo "  2. Configure Firewall: sudo ./08-setup-firewall.sh"
echo "  3. Setup Monitoring: sudo ./09-setup-monitoring.sh"
echo ""
