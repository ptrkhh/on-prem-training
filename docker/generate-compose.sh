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

# Validate critical passwords are not default
echo "=== Validating Passwords ==="
ERRORS=0
if [[ "${GRAFANA_ADMIN_PASSWORD:-admin}" == "admin" ]]; then
    echo "ERROR: GRAFANA_ADMIN_PASSWORD is still set to default 'admin'"
    ((ERRORS++))
fi

if [[ "${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}" == "changeme_guacamole_password" ]]; then
    echo "ERROR: GUACAMOLE_DB_PASSWORD is still set to default"
    ((ERRORS++))
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "Please update passwords in config.sh or .env before generating docker-compose.yml"
    exit 1
fi
echo "✓ Password validation passed"
echo ""

# Check Docker Compose version (v2 only)
echo "=== Checking Docker Compose Version ==="
if ! command -v docker &> /dev/null; then
    echo "ERROR: docker command not found. Please install Docker first."
    exit 1
fi

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
if [[ ! -f "${SCRIPT_DIR}/prometheus/prometheus.yml" ]]; then
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
    # Query maximum supported CUDA version directly from nvidia-smi
    DETECTED_CUDA=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader | head -n1)

    if [[ -n "${DETECTED_CUDA}" ]]; then
        CUDA_BUILD_VERSION="${DETECTED_CUDA}"
        echo "Auto-detected maximum supported CUDA version: ${CUDA_BUILD_VERSION}"
        echo "  (Source: nvidia-smi --query-gpu=cuda_version)"
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

# Warn about default passwords
if [[ "${GRAFANA_ADMIN_PASSWORD:-admin}" == "admin" || "${GRAFANA_ADMIN_PASSWORD}" == "changeme_secure_password" ]]; then
    echo "⚠️  WARNING: Grafana is using default password"
    echo "   Set GRAFANA_ADMIN_PASSWORD in config.sh for security"
    echo ""
fi

###############################################################################
# Write the complete docker-compose.yml
###############################################################################

cat > "${OUTPUT_FILE}" << 'EOFMAIN'
# ML Training Server
# Infrastructure + Per-User VM-like Containers

networks:
  ml-net:
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
  kasm-data:

services:
  #============================================================================
  # INFRASTRUCTURE SERVICES (Shared)
  #============================================================================

  # Traefik - Reverse Proxy & Router
  traefik:
    image: traefik:v3.0
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
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}
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
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}
    networks:
      - ml-net
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        # Check if Guacamole schema is already initialized
        echo "Checking if Guacamole schema exists..."
        SCHEMA_EXISTS=\$(PGPASSWORD="${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}" psql -h guacamole-db -U guacamole_user -d guacamole_db -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='guacamole_user';" 2>/dev/null || echo "0")

        if [ "\$SCHEMA_EXISTS" != "0" ]; then
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
        if ! PGPASSWORD="${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}" psql -h guacamole-db -U guacamole_user -d guacamole_db -f /tmp/initdb.sql > /tmp/initdb.log 2>&1; then
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
      - POSTGRES_PASSWORD=${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}
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
      - "traefik.http.middlewares.guacamole-prefix.stripprefix.prefixes=/guacamole"
      - "traefik.http.routers.guacamole.middlewares=guacamole-prefix"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080/guacamole || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Kasm Workspaces - Container Streaming Platform
  kasm:
    image: kasmweb/workspaces:latest
    container_name: kasm
    restart: unless-stopped
    privileged: true
    environment:
      - KASM_PORT=443
    volumes:
      - kasm-data:/opt/kasm/current
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kasm.rule=Host(\"kasm.${DOMAIN}\")"
      - "traefik.http.routers.kasm.entrypoints=web"
      - "traefik.http.services.kasm.loadbalancer.server.port=443"
      - "traefik.http.services.kasm.loadbalancer.server.scheme=https"

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
    volumes:
      - ${MOUNT_POINT:-/mnt/storage}:/srv
    networks:
      - ml-net
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
    UID=$((FIRST_UID + USER_INDEX))

    # Pre-process username to uppercase for environment variable lookup
    USERNAME_UPPER=$(echo "${USERNAME}" | tr '[:lower:]' '[:upper:]')

    # SSH port: SSH_BASE_PORT + user_index
    SSH_PORT=$((SSH_BASE_PORT + USER_INDEX))

    # VNC port: VNC_BASE_PORT + user_index
    VNC_PORT=$((VNC_BASE_PORT + USER_INDEX))

    # RDP port: RDP_BASE_PORT + user_index
    RDP_PORT=$((RDP_BASE_PORT + USER_INDEX))

    # noVNC port: NOVNC_BASE_PORT + user_index
    NOVNC_PORT=$((NOVNC_BASE_PORT + USER_INDEX))

    echo "Adding user container: ${USERNAME} (UID: ${UID}, SSH: ${SSH_PORT}, VNC: ${VNC_PORT}, RDP: ${RDP_PORT}, noVNC: ${NOVNC_PORT})"

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
    privileged: true  # For Docker-in-Docker
    environment:
      - USER_NAME=${USERNAME}
      - USER_UID=${UID}
      - USER_GID=${UID}
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
      - "${NOVNC_PORT}:6080"     # noVNC (HTML5 VNC client)
    deploy:
      resources:
        limits:
          memory: ${MEMORY_LIMIT_GB:-100}G
          cpus: '${CPU_LIMIT:-32}'  # Maximum CPU cores per container (prevents monopolization)
        reservations:
          memory: ${MEMORY_GUARANTEE_GB:-32}G
          cpus: '${CPU_GUARANTEE:-8}'  # Guaranteed CPU cores per container
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "pgrep", "-f", "Xvnc"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      # Desktop (noVNC HTML5)
      - "traefik.http.routers.${USERNAME}-desktop.rule=Host(\"${USERNAME}-desktop.${DOMAIN}\") || Host(\"${USERNAME}.${DOMAIN}\")"
      - "traefik.http.routers.${USERNAME}-desktop.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-desktop.service=${USERNAME}-desktop"
      - "traefik.http.services.${USERNAME}-desktop.loadbalancer.server.port=6080"
      # Code-server (VS Code in browser)
      - "traefik.http.routers.${USERNAME}-code.rule=Host(\"${USERNAME}-code.${DOMAIN}\")"
      - "traefik.http.routers.${USERNAME}-code.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-code.service=${USERNAME}-code"
      - "traefik.http.services.${USERNAME}-code.loadbalancer.server.port=8080"
      # Jupyter Lab
      - "traefik.http.routers.${USERNAME}-jupyter.rule=Host(\"${USERNAME}-jupyter.${DOMAIN}\")"
      - "traefik.http.routers.${USERNAME}-jupyter.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-jupyter.service=${USERNAME}-jupyter"
      - "traefik.http.services.${USERNAME}-jupyter.loadbalancer.server.port=8888"
      # Per-user TensorBoard
      - "traefik.http.routers.${USERNAME}-tensorboard.rule=Host(\"${USERNAME}-tensorboard.${DOMAIN}\")"
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
echo "  - User workspaces: ${USER_COUNT} containers (with VNC/RDP via Guacamole/Kasm)"
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
echo "  Remote Desktop Gateways:"
echo "    - Guacamole: http://guacamole.${DOMAIN} (primary web gateway)"
echo "    - Kasm Workspaces: http://kasm.${DOMAIN} (alternative streaming platform)"
echo ""
echo "  Per-user services:"
USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    SSH_PORT=$((SSH_BASE_PORT + USER_INDEX))
    VNC_PORT=$((VNC_BASE_PORT + USER_INDEX))
    RDP_PORT=$((RDP_BASE_PORT + USER_INDEX))
    NOVNC_PORT=$((NOVNC_BASE_PORT + USER_INDEX))
    echo "    ${USERNAME}:"
    echo "      - Desktop (Web): http://${USERNAME}-desktop.${DOMAIN} or http://${USERNAME}.${DOMAIN}"
    echo "      - Desktop (Guacamole): http://guacamole.${DOMAIN} → Select ${USERNAME}-desktop"
    echo "      - Desktop (Kasm): http://kasm.${DOMAIN} → Launch ${USERNAME} workspace"
    echo "      - Desktop (VNC Direct): SERVER_IP:${VNC_PORT}"
    echo "      - Desktop (RDP Direct): SERVER_IP:${RDP_PORT}"
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
echo "  - noVNC (HTML5) to ports ${NOVNC_BASE_PORT}, $((NOVNC_BASE_PORT+1)), $((NOVNC_BASE_PORT+2)), etc."
echo ""
echo "Cloudflare Tunnel (internet access):"
echo "  - Routes *.${DOMAIN} through Cloudflare to Traefik on port 80"
echo "  - Local users automatically bypass internet (same network)"
echo "  - Run: ./06-setup-cloudflare-tunnel.sh to configure"
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

# Service passwords
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin}
GUACAMOLE_DB_PASSWORD=${GUACAMOLE_DB_PASSWORD:-changeme_guacamole_password}

# Resource limits
MEMORY_LIMIT_GB=${MEMORY_LIMIT_GB:-100}
MEMORY_GUARANTEE_GB=${MEMORY_GUARANTEE_GB:-32}
CPU_LIMIT=${CPU_LIMIT:-32}
CPU_GUARANTEE=${CPU_GUARANTEE:-8}
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
echo "     (Use the Docker Compose V2 CLI plugin so deploy.resources limits are enforced.)"
echo "  4. Setup Cloudflare Tunnel (for remote access)"
echo ""
