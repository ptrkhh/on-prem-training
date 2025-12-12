#!/bin/bash
set -euo pipefail

# Generate docker-compose.yml with proper architecture:
# - Infrastructure services (shared): Traefik, Netdata, Prometheus, Grafana, etc.
# - Per-user workspace containers (one container per user with full desktop + VNC/RDP)
# - Cloudflare Tunnel + Traefik routing
# - Local network direct access support

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example"
    exit 1
fi

source "${CONFIG_FILE}"

# Check Docker Compose version (v2 only)
echo "=== Checking Docker Compose Version ==="
if ! command -v docker &> /dev/null; then
    echo "ERROR: docker command not found. Please install Docker first."
    exit 1
fi

# Check if Docker daemon is running and ready
echo "Checking Docker daemon..."
if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not responding"
    echo ""
    echo "Please ensure Docker is installed and running:"
    echo "  systemctl status docker"
    echo "  systemctl start docker"
    echo ""
    echo "If Docker was just started, wait a few seconds and try again."
    exit 1
fi
echo "✓ Docker daemon is ready"
echo ""

# Check for Docker Compose v2 only
if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose v2 not found"
    echo ""
    echo "This setup requires Docker Compose v2 (integrated with Docker CLI)."
    echo "Docker Compose v1 (standalone docker-compose) is no longer supported."
    echo ""
    echo "To install Docker Compose v2:"
    echo "  - On Ubuntu/Debian: apt-get update && apt-get install docker-compose-plugin"
    echo "  - Or follow: https://docs.docker.com/compose/install/"
    echo ""
    exit 1
fi

COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
echo "✓ Docker Compose v2 detected: ${COMPOSE_VERSION}"
echo ""

# Check Prometheus config exists
PROM_CONFIG_FILE="${SCRIPT_DIR}/prometheus/prometheus.yml"
if [[ ! -f "${PROM_CONFIG_FILE}" ]]; then
    echo "ERROR: Prometheus config not found: ${SCRIPT_DIR}/prometheus/prometheus.yml"
    echo "This file is required for monitoring."
    echo ""
    echo "Create it with:"
    echo "  mkdir -p ${SCRIPT_DIR}/prometheus"
    echo "  cat > ${SCRIPT_DIR}/prometheus/prometheus.yml <<'EOF'"
    echo "global:"
    echo "  scrape_interval: 15s"
    echo "scrape_configs:"
    echo "  - job_name: 'node'"
    echo "    static_configs:"
    echo "      - targets: ['node-exporter:9100']"
    echo "EOF"
    exit 1
fi
echo "✓ Prometheus configuration found"
echo ""

echo "=== Validating Prometheus configuration syntax ==="
if command -v promtool &>/dev/null; then
    if ! promtool check config "${PROM_CONFIG_FILE}"; then
        echo "ERROR: promtool validation failed for ${PROM_CONFIG_FILE}"
        exit 1
    fi
else
    echo "promtool not found locally; using prom/prometheus container for validation..."
    PROMTOOL_TIMEOUT_SECONDS=600
    if ! timeout ${PROMTOOL_TIMEOUT_SECONDS} docker run --rm --entrypoint promtool -v "${SCRIPT_DIR}/prometheus:/etc/prometheus:ro" prom/prometheus check config /etc/prometheus/prometheus.yml >/tmp/promtool.log 2>&1; then
        cat /tmp/promtool.log
        echo "ERROR: Prometheus configuration validation failed or timed out after ${PROMTOOL_TIMEOUT_SECONDS}s"
        echo "This could indicate:"
        echo "  - Invalid configuration syntax"
        echo "  - Network issues preventing container image download"
        echo "  - Docker daemon issues"
        exit 1
    fi
    rm -f /tmp/promtool.log
fi
echo "✓ Prometheus configuration syntax looks good"
echo ""

# Check Google Drive mount is healthy
echo "=== Checking Google Drive Mount ==="
MOUNT_POINT="${MOUNT_POINT:-/mnt/storage}"
SHARED_MOUNT="${MOUNT_POINT}/shared"

if [[ ! -d "${SHARED_MOUNT}" ]]; then
    echo "ERROR: Shared mount directory not found: ${SHARED_MOUNT}"
    echo ""
    echo "Please ensure the Google Drive mount is set up:"
    echo "  sudo /home/p/on-prem-training/scripts/fix-gdrive-mount.sh"
    exit 1
fi

if ! mountpoint -q "${SHARED_MOUNT}" 2>/dev/null; then
    echo "ERROR: ${SHARED_MOUNT} is not mounted"
    echo ""
    echo "The Google Drive mount is required for Docker containers."
    echo "Please start the mount service:"
    echo "  sudo systemctl start gdrive-shared.service"
    echo ""
    echo "Or run the fix script:"
    echo "  sudo /home/p/on-prem-training/scripts/fix-gdrive-mount.sh"
    exit 1
fi

# Check if mount is responsive (not stale)
echo "Checking mount responsiveness..."
if ! timeout 10 ls "${SHARED_MOUNT}" >/dev/null 2>&1; then
    echo "ERROR: ${SHARED_MOUNT} is stale (hung/not responsive)"
    echo ""
    echo "The mount appears to be in a hung state. Please fix it:"
    echo "  sudo /home/p/on-prem-training/scripts/fix-gdrive-mount.sh"
    exit 1
fi

echo "✓ Google Drive mount is healthy"
echo ""

# Auto-generate .env file from config.sh
GENERATE_ENV_SCRIPT="${SCRIPT_DIR}/../docker/generate-env.sh"
if [[ -f "${GENERATE_ENV_SCRIPT}" ]]; then
    echo "=== Auto-generating docker/.env from config.sh ==="
    bash "${GENERATE_ENV_SCRIPT}"
    echo ""
else
    echo "⚠ WARNING: generate-env.sh not found, skipping .env generation"
    echo ""
fi

# Determine CUDA version (manual override or auto-detect)
if [[ -n "${CUDA_VERSION}" ]]; then
    # Manual override from config.sh
    CUDA_BUILD_VERSION="${CUDA_VERSION}"
    echo "Using manually configured CUDA version: ${CUDA_BUILD_VERSION}"
    echo "  (Set in config.sh CUDA_VERSION variable)"
elif command -v nvidia-smi &>/dev/null; then
    # Parse CUDA version from nvidia-smi header output
    DETECTED_CUDA=$(nvidia-smi | grep -oP "CUDA Version: \K[0-9]+\.[0-9]+" | head -n1)

    if [[ -n "${DETECTED_CUDA}" ]]; then
        CUDA_BUILD_VERSION="${DETECTED_CUDA}"
        echo "Auto-detected maximum supported CUDA version: ${CUDA_BUILD_VERSION}"
        echo "  (Source: nvidia-smi output)"
    else
        # Cannot detect CUDA version - require manual specification
        echo "ERROR: Could not auto-detect CUDA version from nvidia-smi"
        echo ""
        echo "Please manually specify CUDA_VERSION in config.sh"
        echo "Example: CUDA_VERSION=\"12.4.1\""
        echo ""
        echo "To determine your CUDA version:"
        echo "  1. Check your NVIDIA driver version: nvidia-smi"
        echo "  2. Find compatible CUDA version: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/"
        echo "  3. Set CUDA_VERSION in config.sh to match your driver"
        exit 1
    fi
else
    echo "ERROR: nvidia-smi not found - cannot detect CUDA version"
    echo ""
    echo "Please manually specify CUDA_VERSION in config.sh"
    echo "Example: CUDA_VERSION=\"12.4.1\""
    echo ""
    echo "To determine your CUDA version:"
    echo "  1. Install NVIDIA drivers if not already installed"
    echo "  2. Run: nvidia-smi"
    echo "  3. Find compatible CUDA version: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/"
    echo "  4. Set CUDA_VERSION in config.sh to match your driver"
    exit 1
fi

# Fetch latest patch version from Docker Hub if only major.minor version was detected
if [[ -n "${CUDA_BUILD_VERSION}" ]]; then
    # Check if version is in major.minor format (e.g., 13.0) without patch version
    if [[ "${CUDA_BUILD_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo ""
        echo "=== Fetching Latest CUDA Patch Version from Docker Hub ==="
        echo "Detected CUDA version: ${CUDA_BUILD_VERSION} (major.minor only)"
        echo "Querying Docker Hub for latest patch version..."

        # Suffix for the Docker image tag
        CUDA_IMAGE_SUFFIX="cudnn-runtime-ubuntu24.04"

        # Fetch the latest patch version from Docker Hub
        LATEST_PATCH_VERSION=$(curl -s "https://registry.hub.docker.com/v2/repositories/nvidia/cuda/tags/?page_size=200" | \
python3 -c "
import sys, json
cv = '${CUDA_BUILD_VERSION}'
sf = '${CUDA_IMAGE_SUFFIX}'
try:
    data = json.load(sys.stdin)
    tags = [t['name'] for t in data['results']
            if t['name'].startswith(cv + '.') and t['name'].endswith(sf)]
    if tags:
        # Sort by version number (extract version part before first dash)
        tags.sort(key=lambda x: [int(n) for n in x.split('-')[0].split('.')])
        latest_tag = tags[-1]
        # Extract just the version part (before the first dash)
        version = latest_tag.split('-')[0]
        print(version)
    else:
        sys.exit(1)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

        if [[ -n "${LATEST_PATCH_VERSION}" ]]; then
            CUDA_BUILD_VERSION="${LATEST_PATCH_VERSION}"
            echo "✓ Found latest patch version: ${CUDA_BUILD_VERSION}"
            echo "  Full image tag: nvidia/cuda:${CUDA_BUILD_VERSION}-${CUDA_IMAGE_SUFFIX}"
        else
            echo "⚠️  WARNING: Could not fetch latest patch version from Docker Hub"
            echo "  Falling back to detected version: ${CUDA_BUILD_VERSION}"
            echo "  You may want to manually specify the full version in config.sh"
            echo "  Example: CUDA_VERSION=\"${CUDA_BUILD_VERSION}.2\""
        fi
        echo ""
    fi
fi

# Validate CUDA version format
if [[ -n "${CUDA_BUILD_VERSION}" ]]; then
    if ! [[ "${CUDA_BUILD_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Invalid CUDA version format: ${CUDA_BUILD_VERSION}"
        echo "Expected format: X.Y or X.Y.Z (e.g., '12.4' or '12.4.1')"
        echo ""
        echo "Valid examples:"
        echo "  CUDA_VERSION=\"12.4.1\""
        echo "  CUDA_VERSION=\"11.8\""
        exit 1
    fi
    echo "✓ CUDA version format validated: ${CUDA_BUILD_VERSION}"
    echo ""
fi

# Validate required configuration
if [[ -z "${DOMAIN}" ]]; then
    echo "ERROR: DOMAIN is not set in config.sh"
    echo "Please set DOMAIN to your domain name (e.g., example.com)"
    exit 1
fi

OUTPUT_FILE="${SCRIPT_DIR}/docker-compose.yml"

echo "=== Generating docker-compose.yml ==="
echo "Users: ${USERS}"
echo "Domain: ${DOMAIN}"
echo ""

# Convert users string to array
USER_ARRAY=(${USERS})
USER_COUNT=${#USER_ARRAY[@]}

echo "Creating docker-compose.yml with:"
echo "  - Infrastructure services (Traefik, monitoring, storage)"
echo "  - ${USER_COUNT} user workspace containers (with VNC/RDP remote desktop)"
echo ""

# Validate required passwords are set (no defaults allowed)
MISSING_PASSWORDS=()

if [[ -z "${GUACAMOLE_DB_PASSWORD:-}" ]]; then
    MISSING_PASSWORDS+=("GUACAMOLE_DB_PASSWORD")
fi

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" || "${GRAFANA_ADMIN_PASSWORD}" == "admin" ]]; then
    MISSING_PASSWORDS+=("GRAFANA_ADMIN_PASSWORD")
fi

if [[ -z "${FILEBROWSER_ADMIN_PASSWORD:-}" ]]; then
    MISSING_PASSWORDS+=("FILEBROWSER_ADMIN_PASSWORD")
fi

if [[ ${#MISSING_PASSWORDS[@]} -gt 0 ]]; then
    echo "ERROR: Required passwords not set in config.sh:"
    for missing_pass in "${MISSING_PASSWORDS[@]}"; do
        echo "  - ${missing_pass}"
    done
    echo ""
    echo "Please set these passwords in config.sh before generating docker-compose.yml"
    echo "Security requirement: No default passwords are allowed"
    exit 1
fi

###############################################################################
# Write the complete docker-compose.yml
###############################################################################

cat > "${OUTPUT_FILE}" << 'EOFMAIN'
# ML Training Server
# Infrastructure + Per-User VM-like Containers

networks:
  ml-net:
    name: ml-net
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}

volumes:
  prometheus-data:
  grafana-data:
  portainer-data:
  dozzle-data:
  guacamole-db-data:

services:
  #============================================================================
  # INFRASTRUCTURE SERVICES (Shared)
  #============================================================================

  # Traefik - Reverse Proxy & Router
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    command:
      # API and Dashboard
      - "--api.dashboard=true"
      - "--api.insecure=true"
      # Docker provider
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=ml-net"
      # Entrypoints
      - "--entrypoints.web.address=:80"
      - "--log.level=INFO"
      # Access logs
      - "--accesslog=true"
      # Health check endpoint
      - "--ping=true"
    ports:
      - "80:80"      # HTTP (local network + Cloudflare Tunnel)
      - "8080:8080"  # Traefik Dashboard
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - ml-net
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  # Apache Guacamole - Clientless Remote Desktop Gateway
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "netstat -an | grep -q 4822"]
      interval: 10s
      timeout: 5s
      retries: 3

  guacamole-db:
    image: postgres:15
    container_name: guacamole-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=guacamole_db
      - POSTGRES_USER=guacamole_user
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD}
    volumes:
      - guacamole-db-data:/var/lib/postgresql/data
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U guacamole_user -d guacamole_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  guacamole-db-init:
    image: guacamole/guacamole:latest
    container_name: guacamole-db-init
    depends_on:
      guacamole-db:
        condition: service_healthy
    environment:
      - POSTGRES_HOSTNAME=guacamole-db
      - POSTGRES_DATABASE=guacamole_db
      - POSTGRES_USER=guacamole_user
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD}
    networks:
      - ml-net
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        # Check if Guacamole schema is already initialized
        echo "Checking if Guacamole schema exists..."
        SCHEMA_EXISTS=$$(PGPASSWORD="${GUACAMOLE_DB_PASSWORD}" psql -h guacamole-db -U guacamole_user -d guacamole_db -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='guacamole_user';" 2>/dev/null || echo "0")

        if [ "$$SCHEMA_EXISTS" != "0" ]; then
          echo "Guacamole schema already exists, skipping initialization"
          exit 0
        fi

        # Generate and apply Guacamole schema
        echo "Initializing Guacamole database schema..."
        /opt/guacamole/bin/initdb.sh --postgresql > /tmp/initdb.sql

        if [ ! -s /tmp/initdb.sql ]; then
          echo "ERROR: Failed to generate Guacamole schema"
          exit 1
        fi

        # Apply schema and log all output
        if ! PGPASSWORD="${GUACAMOLE_DB_PASSWORD}" psql -h guacamole-db -U guacamole_user -d guacamole_db -f /tmp/initdb.sql > /tmp/initdb.log 2>&1; then
          echo "ERROR: Failed to apply Guacamole schema"
          cat /tmp/initdb.log
          exit 1
        fi

        echo "Guacamole database schema initialized successfully"
        cat /tmp/initdb.log
    restart: "no"

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole
    restart: unless-stopped
    environment:
      - GUACD_HOSTNAME=guacd
      - POSTGRES_HOSTNAME=guacamole-db
      - POSTGRES_DATABASE=guacamole_db
      - POSTGRES_USER=guacamole_user
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD}
    depends_on:
      - guacd
      - guacamole-db-init
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.guacamole.rule=Host(`guacamole.${DOMAIN}`) || Host(`remote.${DOMAIN}`)"
      - "traefik.http.routers.guacamole.entrypoints=web"
      - "traefik.http.services.guacamole.loadbalancer.server.port=8080"
      # Redirect root to /guacamole/ for convenience
      - "traefik.http.middlewares.guacamole-redirect.redirectregex.regex=^http://(.*)/$$"
      - "traefik.http.middlewares.guacamole-redirect.redirectregex.replacement=http://$${1}/guacamole/"
      - "traefik.http.routers.guacamole.middlewares=guacamole-redirect"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080/guacamole || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Netdata - Real-time System Monitoring
  netdata:
    image: netdata/netdata:latest
    container_name: netdata
    restart: unless-stopped
    hostname: ml-train-server
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
    environment:
      - DOCKER_HOST=/var/run/docker.sock
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netdata.rule=Host(`health.${DOMAIN}`)"
      - "traefik.http.routers.netdata.entrypoints=web"
      - "traefik.http.services.netdata.loadbalancer.server.port=19999"

  # Prometheus - Metrics Backend
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9090/-/healthy || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: '2.0'
        reservations:
          memory: 1G
          cpus: '0.5'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.prometheus.rule=Host(`prometheus.${DOMAIN}`)"
      - "traefik.http.routers.prometheus.entrypoints=web"
      - "traefik.http.services.prometheus.loadbalancer.server.port=9090"

  # Grafana - Metrics Visualization
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '2.0'
        reservations:
          memory: 512M
          cpus: '0.5'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`grafana.${DOMAIN}`)"
      - "traefik.http.routers.grafana.entrypoints=web"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"

  # Node Exporter - System Metrics for Prometheus
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
      - '--collector.textfile.directory=/var/lib/node_exporter/textfile_collector'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
      - /var/lib/node_exporter/textfile_collector:/var/lib/node_exporter/textfile_collector:ro
    networks:
      - ml-net

  # cAdvisor - Container Metrics
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:rw
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks:
      - ml-net

  # Shared TensorBoard
  tensorboard:
    image: tensorflow/tensorflow:latest
    container_name: tensorboard
    restart: unless-stopped
    command: tensorboard --logdir=/logs --host=0.0.0.0 --port=6006
    volumes:
      - ${MOUNT_POINT:-/mnt/storage}/shared/tensorboard:/logs:ro
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:6006 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.tensorboard.rule=Host(`tensorboard.${DOMAIN}`)"
      - "traefik.http.routers.tensorboard.entrypoints=web"
      - "traefik.http.services.tensorboard.loadbalancer.server.port=6006"

  # FileBrowser - File Management
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    restart: unless-stopped
    user: "0:0"
    environment:
      - FB_DATABASE=/database/filebrowser.db
      - FB_CONFIG=/config/settings.json
      - FB_USERNAME=admin
      - FB_PASSWORD=${FILEBROWSER_ADMIN_PASSWORD}
    volumes:
      - ${MOUNT_POINT:-/mnt/storage}:/srv
      - ${MOUNT_POINT:-/mnt/storage}/filebrowser-db:/database
      - ${MOUNT_POINT:-/mnt/storage}/filebrowser-config:/config
    networks:
      - ml-net
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:80 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.filebrowser.rule=Host(`files.${DOMAIN}`)"
      - "traefik.http.routers.filebrowser.entrypoints=web"
      - "traefik.http.services.filebrowser.loadbalancer.server.port=80"

  # Dozzle - Container Logs
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - dozzle-data:/data
    environment:
      - DOZZLE_LEVEL=info
      - DOZZLE_TAILSIZE=300
      - DOZZLE_FILTER=status=running
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dozzle.rule=Host(`logs.${DOMAIN}`)"
      - "traefik.http.routers.dozzle.entrypoints=web"
      - "traefik.http.services.dozzle.loadbalancer.server.port=8080"

  # Portainer - Container Management
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(`portainer.${DOMAIN}`)"
      - "traefik.http.routers.portainer.entrypoints=web"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

  #============================================================================
  # USER WORKSPACE CONTAINERS (One per user)
  #============================================================================

EOFMAIN

###############################################################################
# USER CONTAINERS
###############################################################################

USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    USER_UID=$((FIRST_UID + USER_INDEX))

    # Pre-process username to uppercase for environment variable lookup
    USERNAME_UPPER=$(echo "${USERNAME}" | tr '[:lower:]' '[:upper:]')

    # SSH port: SSH_BASE_PORT + user_index
    SSH_PORT=$((SSH_BASE_PORT + USER_INDEX))

    # VNC port: VNC_BASE_PORT + user_index
    VNC_PORT=$((VNC_BASE_PORT + USER_INDEX))

    # RDP port: RDP_BASE_PORT + user_index
    RDP_PORT=$((RDP_BASE_PORT + USER_INDEX))

    # KasmVNC web interface port: NOVNC_BASE_PORT + user_index (reusing the same base port)
    KASMVNC_PORT=$((NOVNC_BASE_PORT + USER_INDEX))

    echo "Adding user container: ${USERNAME} (UID: ${USER_UID}, SSH: ${SSH_PORT}, VNC: ${VNC_PORT}, RDP: ${RDP_PORT}, KasmVNC: ${KASMVNC_PORT})"

    cat >> "${OUTPUT_FILE}" << EOF
  # User: ${USERNAME}
  workspace-${USERNAME}:
    build:
      context: ..
      dockerfile: docker/Dockerfile.user-workspace
      args:
        - CUDA_VERSION=${CUDA_BUILD_VERSION}
    image: ml-workspace:latest
    container_name: workspace-${USERNAME}
    hostname: ${USERNAME}-workspace
    restart: unless-stopped
    stop_grace_period: 5m  # Allow 5 minutes for graceful shutdown (checkpoint saving, etc.)
    privileged: true  # For Docker-in-Docker
    environment:
      - USER_NAME=${USERNAME}
      - USER_UID=${USER_UID}
      - USER_GID=${USER_UID}
      - USER_PASSWORD=\${USER_${USERNAME_UPPER}_PASSWORD:-changeme}
      - CODE_SERVER_PASSWORD=\${USER_${USERNAME_UPPER}_PASSWORD:-changeme}
      - USER_GROUPS=${USER_GROUPS}
      - REQUIRE_GPU=${REQUIRE_GPU}
      - DISPLAY=:0
      - WORKSPACE=/workspace
      - SHARED=/shared
    volumes:
      # Persistent home directory
      - ${MOUNT_POINT:-/mnt/storage}/homes/${USERNAME}:/home/${USERNAME}:rw
      # Ephemeral workspace (fast scratch space)
      - ${MOUNT_POINT:-/mnt/storage}/workspaces/${USERNAME}:/workspace:rw
      # Shared data (read-write for all users to share files)
      - ${MOUNT_POINT:-/mnt/storage}/shared:/shared:rw
      # Container state (Docker data root)
      - ${MOUNT_POINT:-/mnt/storage}/docker-volumes/${USERNAME}-state:/var/lib/state:rw
      # Shared caches (for all users to benefit from cached downloads)
      - ${MOUNT_POINT:-/mnt/storage}/cache/ml-models:/cache/ml-models:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/pip:/cache/pip:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/conda:/cache/conda:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/apt:/var/cache/apt:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/git-lfs:/cache/git-lfs:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/go:/cache/go:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/npm:/cache/npm:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/cargo:/cache/cargo:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/julia:/cache/julia:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/R:/cache/R:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/buildkit:/cache/buildkit:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/browser:/cache/browser:rw
      - ${MOUNT_POINT:-/mnt/storage}/cache/jetbrains:/cache/jetbrains:rw
    ports:
      - "${SSH_PORT}:22"         # SSH (for terminal access)
      - "${VNC_PORT}:5900"       # VNC (for Guacamole/direct VNC clients)
      - "${RDP_PORT}:3389"       # XRDP (for Guacamole/direct RDP clients)
      - "${KASMVNC_PORT}:6901"   # KasmVNC web interface (HTML5 client)
    deploy:
      resources:
        limits:
          memory: ${MEMORY_LIMIT_GB:-100}G
          cpus: '${CPU_LIMIT:-32}'
        reservations:
          memory: ${MEMORY_GUARANTEE_GB:-32}G
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x supervisord && pgrep -x sshd && pgrep -f websockify"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      # Desktop (KasmVNC web interface)
      - "traefik.http.routers.${USERNAME}-desktop.rule=Host(\`${USERNAME}-desktop.${DOMAIN}\`) || Host(\`${USERNAME}.${DOMAIN}\`)"
      - "traefik.http.routers.${USERNAME}-desktop.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-desktop.service=${USERNAME}-desktop"
      - "traefik.http.services.${USERNAME}-desktop.loadbalancer.server.port=6901"
      # Code-server (VS Code in browser)
      - "traefik.http.routers.${USERNAME}-code.rule=Host(\`${USERNAME}-code.${DOMAIN}\`)"
      - "traefik.http.routers.${USERNAME}-code.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-code.service=${USERNAME}-code"
      - "traefik.http.services.${USERNAME}-code.loadbalancer.server.port=8080"
      # Jupyter Lab
      - "traefik.http.routers.${USERNAME}-jupyter.rule=Host(\`${USERNAME}-jupyter.${DOMAIN}\`)"
      - "traefik.http.routers.${USERNAME}-jupyter.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-jupyter.service=${USERNAME}-jupyter"
      - "traefik.http.services.${USERNAME}-jupyter.loadbalancer.server.port=8888"
      # Per-user TensorBoard
      - "traefik.http.routers.${USERNAME}-tensorboard.rule=Host(\`${USERNAME}-tensorboard.${DOMAIN}\`)"
      - "traefik.http.routers.${USERNAME}-tensorboard.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-tensorboard.service=${USERNAME}-tensorboard"
      - "traefik.http.services.${USERNAME}-tensorboard.loadbalancer.server.port=6006"

EOF

    USER_INDEX=$((USER_INDEX + 1))
done

echo ""
echo "✅ Generated: ${OUTPUT_FILE}"
echo ""
echo "Services created:"
echo "  - Infrastructure: 9 services (Traefik, Netdata, Prometheus, Grafana, etc.)"
echo "  - User workspaces: ${USER_COUNT} containers (KasmVNC + Guacamole backup)"
echo ""
echo "Access URLs (via Cloudflare Tunnel or local network):"
echo "  Infrastructure:"
echo "    - Netdata (Health): http://health.${DOMAIN}"
echo "    - Prometheus: http://prometheus.${DOMAIN}"
echo "    - Grafana: http://grafana.${DOMAIN}"
echo "    - TensorBoard (Shared): http://tensorboard.${DOMAIN}"
echo "    - FileBrowser: http://files.${DOMAIN}"
echo "    - Dozzle (Logs): http://logs.${DOMAIN}"
echo "    - Portainer: http://portainer.${DOMAIN}"
echo ""
echo "  Remote Desktop Gateway:"
echo "    - Guacamole: http://guacamole.${DOMAIN} (web-based remote desktop gateway)"
echo ""
echo "  Per-user services:"
USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    SSH_PORT=$((SSH_BASE_PORT + USER_INDEX))
    VNC_PORT=$((VNC_BASE_PORT + USER_INDEX))
    RDP_PORT=$((RDP_BASE_PORT + USER_INDEX))
    KASMVNC_PORT=$((NOVNC_BASE_PORT + USER_INDEX))
    echo "    ${USERNAME}:"
    echo "      - Desktop (KasmVNC): http://${USERNAME}-desktop.${DOMAIN} or http://${USERNAME}.${DOMAIN}"
    echo "      - Desktop (Guacamole backup): http://guacamole.${DOMAIN} → Select ${USERNAME}-desktop"
    echo "      - Desktop (VNC Direct): SERVER_IP:${VNC_PORT}"
    echo "      - Desktop (RDP Direct): SERVER_IP:${RDP_PORT}"
    echo "      - Desktop (KasmVNC Direct): SERVER_IP:${KASMVNC_PORT}"
    echo "      - VS Code: http://${USERNAME}-code.${DOMAIN}"
    echo "      - Jupyter: http://${USERNAME}-jupyter.${DOMAIN}"
    echo "      - TensorBoard: http://${USERNAME}-tensorboard.${DOMAIN}"
    echo "      - SSH: ssh ${USERNAME}@SERVER_IP -p ${SSH_PORT}"
    USER_INDEX=$((USER_INDEX + 1))
done
echo ""
echo "Local network access:"
echo "  - Point *.${DOMAIN} to server IP in /etc/hosts or local DNS"
echo "  - All services accessible via http://hostname.${DOMAIN}"
echo "  - SSH directly to ports ${SSH_BASE_PORT}, $((SSH_BASE_PORT+1)), $((SSH_BASE_PORT+2)), etc."
echo "  - VNC directly to ports ${VNC_BASE_PORT}, $((VNC_BASE_PORT+1)), $((VNC_BASE_PORT+2)), etc."
echo "  - RDP directly to ports ${RDP_BASE_PORT}, $((RDP_BASE_PORT+1)), $((RDP_BASE_PORT+2)), etc."
echo "  - KasmVNC web to ports ${NOVNC_BASE_PORT}, $((NOVNC_BASE_PORT+1)), $((NOVNC_BASE_PORT+2)), etc."
echo ""
echo "Cloudflare Tunnel (internet access):"
echo "  - Routes *.${DOMAIN} through Cloudflare to Traefik on port 80"
echo "  - Local users automatically bypass internet (same network)"
echo "  - Run: ./07-setup-cloudflare-tunnel.sh to configure"
echo ""
echo "Cache directories mounted (shared across all users):"
echo "  - ML Models: /cache/ml-models (HuggingFace, PyTorch Hub, TensorFlow Hub)"
echo "  - Python pip: /cache/pip"
echo "  - Conda packages: /cache/conda"
echo "  - APT packages: /var/cache/apt"
echo "  - Language caches: Go, npm, Rust cargo, Julia, R"
echo "  - JetBrains IDEs: /cache/jetbrains"
echo "  - Docker layers: /cache/docker-layers"
echo ""
echo "Benefits:"
echo "  - First user downloads packages/models → cached for all users"
echo "  - Faster pip installs (10-50x for cached wheels)"
echo "  - Faster Docker builds (shared build cache)"
echo "  - Reduced bandwidth (no redundant downloads)"
echo ""

# Validate generated docker-compose.yml
if command -v docker &>/dev/null; then
    if docker compose -f "${OUTPUT_FILE}" config &>/dev/null; then
        echo "✓ Generated docker-compose.yml is valid"
    else
        echo "⚠️  WARNING: Generated docker-compose.yml may have syntax errors"
        echo "   Run: docker compose config to validate"
    fi
else
    echo "⚠️  WARNING: Docker not available, skipping validation"
fi
echo ""

# Generate .env file
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "=== Generating .env file ==="
    cat > "${ENV_FILE}" << EOF
# ML Training Server Environment Variables
# Generated by generate-compose.sh

# Domain configuration
DOMAIN=${DOMAIN}

# Storage mount point
MOUNT_POINT=${MOUNT_POINT:-/mnt/storage}

# Service passwords (validated at generation time - no defaults allowed)
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
GUACAMOLE_DB_PASSWORD=${GUACAMOLE_DB_PASSWORD}
FILEBROWSER_ADMIN_PASSWORD=${FILEBROWSER_ADMIN_PASSWORD}

# Resource limits
MEMORY_LIMIT_GB=${MEMORY_LIMIT_GB:-100}
MEMORY_GUARANTEE_GB=${MEMORY_GUARANTEE_GB:-32}
CPU_LIMIT=${CPU_LIMIT:-32}
EOF
    echo "✅ Generated: ${ENV_FILE}"
    echo "⚠️  IMPORTANT: Update passwords in .env file before deployment!"
    echo ""
else
    echo "⚠️  .env file already exists, skipping generation"
    echo ""
fi

echo "Next steps:"
echo "  1. Review and update passwords in .env file"
echo "  2. Build images (with parallel builds for faster execution):"
echo "     export DOCKER_BUILDKIT=1"
echo "     export COMPOSE_DOCKER_CLI_BUILD=1"
echo "     docker compose build --parallel"
echo "  3. Start services: docker compose up -d"
echo "     (Per-user CPU/RAM limits are applied via deploy.resources)"
echo "  4. Setup Cloudflare Tunnel (for remote access)"
echo ""
