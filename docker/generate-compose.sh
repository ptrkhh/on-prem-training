#!/bin/bash
set -euo pipefail

# Generate docker-compose.yml with proper architecture:
# - Infrastructure services (shared): Traefik, Netdata, Prometheus, Grafana, etc.
# - Per-user workspace containers (one container per user with full desktop + NoMachine)
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
echo "  - ${USER_COUNT} user workspace containers (with NoMachine remote desktop)"
echo ""

###############################################################################
# Write the complete docker-compose.yml
###############################################################################

cat > "${OUTPUT_FILE}" << 'EOFMAIN'
version: '3.8'

# ML Training Server
# Infrastructure + Per-User VM-like Containers

networks:
  ml-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16

volumes:
  prometheus-data:
  grafana-data:
  portainer-data:
  dozzle-data:

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

  # NoMachine Remote Desktop
  # Note: NoMachine servers run inside each user workspace container
  # Each user can access their desktop via:
  #  - NoMachine client (download from nomachine.com)
  #  - Web browser at http://<username>-desktop.${DOMAIN}
  # No shared infrastructure needed - simpler and better performance than Guacamole

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
      - "traefik.http.routers.netdata.rule=Host(`health.${DOMAIN:-localhost}`)"
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`metrics.${DOMAIN:-localhost}`)"
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
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
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
      - "traefik.http.routers.tensorboard.rule=Host(`tensorboard.${DOMAIN:-localhost}`)"
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
      - "traefik.http.routers.filebrowser.rule=Host(`files.${DOMAIN:-localhost}`)"
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
      - "traefik.http.routers.dozzle.rule=Host(`logs.${DOMAIN:-localhost}`)"
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
      - "traefik.http.routers.portainer.rule=Host(`portainer.${DOMAIN:-localhost}`)"
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

    # SSH port: 2222 + user_index
    SSH_PORT=$((2222 + USER_INDEX))

    # NoMachine port: 4000 + user_index
    NX_PORT=$((4000 + USER_INDEX))

    # NoMachine web port: 4080 + user_index
    NX_WEB_PORT=$((4080 + USER_INDEX))

    echo "Adding user container: ${USERNAME} (UID: ${UID}, SSH: ${SSH_PORT}, NX: ${NX_PORT}, NX-Web: ${NX_WEB_PORT})"

    cat >> "${OUTPUT_FILE}" << EOF
  # User: ${USERNAME}
  workspace-${USERNAME}:
    build:
      context: .
      dockerfile: Dockerfile.user-workspace
    image: ml-workspace:latest
    container_name: workspace-${USERNAME}
    hostname: ${USERNAME}-workspace
    restart: unless-stopped
    privileged: true  # For Docker-in-Docker
    environment:
      - USER_NAME=${USERNAME}
      - USER_UID=${UID}
      - USER_GID=${UID}
      - USER_PASSWORD=\${USER_${USERNAME^^}_PASSWORD:-changeme}
      - DISPLAY=:0
      - WORKSPACE=/workspace
      - SHARED=/shared
    volumes:
      # Persistent home directory
      - \${MOUNT_POINT:-/mnt/storage}/homes/${USERNAME}:/home/${USERNAME}:rw
      # Ephemeral workspace (fast scratch space)
      - \${MOUNT_POINT:-/mnt/storage}/workspaces/${USERNAME}:/workspace:rw
      # Shared data (read-only for datasets, read-write for tensorboard)
      - \${MOUNT_POINT:-/mnt/storage}/shared:/shared:ro
      - \${MOUNT_POINT:-/mnt/storage}/shared/tensorboard/${USERNAME}:/shared/tensorboard/${USERNAME}:rw
      # Container state
      - \${MOUNT_POINT:-/mnt/storage}/docker-volumes/${USERNAME}-state:/var/lib/state:rw
      # Docker socket for Docker-in-Docker
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "${SSH_PORT}:22"         # SSH (for terminal access)
      - "${NX_PORT}:4000"        # NoMachine (NX protocol)
      - "${NX_WEB_PORT}:4080"    # NoMachine Web (HTML5 client)
    deploy:
      resources:
        limits:
          memory: \${MEMORY_LIMIT_GB:-100}G
        reservations:
          memory: \${MEMORY_GUARANTEE_GB:-32}G
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ml-net
    labels:
      - "traefik.enable=true"
      # Code-server (VS Code in browser)
      - "traefik.http.routers.${USERNAME}-code.rule=Host(\`${USERNAME}-code.\${DOMAIN:-localhost}\`)"
      - "traefik.http.routers.${USERNAME}-code.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-code.service=${USERNAME}-code"
      - "traefik.http.services.${USERNAME}-code.loadbalancer.server.port=8080"
      # Jupyter Lab
      - "traefik.http.routers.${USERNAME}-jupyter.rule=Host(\`jupyter-${USERNAME}.\${DOMAIN:-localhost}\`)"
      - "traefik.http.routers.${USERNAME}-jupyter.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-jupyter.service=${USERNAME}-jupyter"
      - "traefik.http.services.${USERNAME}-jupyter.loadbalancer.server.port=8888"
      # Per-user TensorBoard
      - "traefik.http.routers.${USERNAME}-tensorboard.rule=Host(\`tensorboard-${USERNAME}.\${DOMAIN:-localhost}\`)"
      - "traefik.http.routers.${USERNAME}-tensorboard.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-tensorboard.service=${USERNAME}-tensorboard"
      - "traefik.http.services.${USERNAME}-tensorboard.loadbalancer.server.port=6006"
      # NoMachine Web Interface
      - "traefik.http.routers.${USERNAME}-desktop.rule=Host(\`${USERNAME}-desktop.\${DOMAIN:-localhost}\`)"
      - "traefik.http.routers.${USERNAME}-desktop.entrypoints=web"
      - "traefik.http.routers.${USERNAME}-desktop.service=${USERNAME}-desktop"
      - "traefik.http.services.${USERNAME}-desktop.loadbalancer.server.port=4080"

EOF

    USER_INDEX=$((USER_INDEX + 1))
done

echo ""
echo "✅ Generated: ${OUTPUT_FILE}"
echo ""
echo "Services created:"
echo "  - Infrastructure: 9 services (Traefik, Netdata, Prometheus, Grafana, etc.)"
echo "  - User workspaces: ${USER_COUNT} containers (each with NoMachine remote desktop)"
echo ""
echo "Access URLs (via Cloudflare Tunnel or local network):"
echo "  Infrastructure:"
echo "    - Netdata (Health): http://health.${DOMAIN}"
echo "    - Grafana (Metrics): http://metrics.${DOMAIN}"
echo "    - TensorBoard (Shared): http://tensorboard.${DOMAIN}"
echo "    - FileBrowser: http://files.${DOMAIN}"
echo "    - Dozzle (Logs): http://logs.${DOMAIN}"
echo "    - Portainer: http://portainer.${DOMAIN}"
echo ""
echo "  Per-user services:"
USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    SSH_PORT=$((2222 + USER_INDEX))
    NX_PORT=$((4000 + USER_INDEX))
    NX_WEB_PORT=$((4080 + USER_INDEX))
    echo "    ${USERNAME}:"
    echo "      - Desktop (NoMachine Web): http://${USERNAME}-desktop.${DOMAIN}"
    echo "      - Desktop (NoMachine Client): SERVER_IP:${NX_PORT}"
    echo "      - VS Code: http://${USERNAME}-code.${DOMAIN}"
    echo "      - Jupyter: http://jupyter-${USERNAME}.${DOMAIN}"
    echo "      - TensorBoard: http://tensorboard-${USERNAME}.${DOMAIN}"
    echo "      - SSH: ssh ${USERNAME}@SERVER_IP -p ${SSH_PORT}"
    USER_INDEX=$((USER_INDEX + 1))
done
echo ""
echo "Local network access:"
echo "  - Point *.${DOMAIN} to server IP in /etc/hosts or local DNS"
echo "  - All services accessible via http://hostname.${DOMAIN}"
echo "  - SSH directly to ports 2222, 2223, 2224, etc."
echo ""
echo "Cloudflare Tunnel (internet access):"
echo "  - Routes *.${DOMAIN} through Cloudflare to Traefik on port 80"
echo "  - Local users automatically bypass internet (same network)"
echo "  - Run: ./04-setup-cloudflare-tunnel.sh to configure"
echo ""
echo "Next steps:"
echo "  1. Create .env file with passwords"
echo "  2. Build image: docker compose build"
echo "  3. Start services: docker compose up -d"
echo "  4. Setup Cloudflare Tunnel (for remote access)"
echo ""
