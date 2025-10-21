#!/bin/bash
set -euo pipefail

# ML Training Server - Cloudflare Tunnel Setup

echo "=== Cloudflare Tunnel Setup ==="

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

# Convert users string to array
USER_ARRAY=(${USERS})
USER_COUNT=${#USER_ARRAY[@]}

# Step 1: Install cloudflared
echo ""
echo "=== Step 1: Installing cloudflared ==="

# Add Cloudflare GPG key
mkdir -p /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

# Add repository
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list

# Install
apt update
apt install -y cloudflared

echo "cloudflared installed: $(cloudflared --version)"

# Step 2: Authenticate and create tunnel
echo ""
echo "=== Step 2: Creating Cloudflare Tunnel ==="
echo ""
echo "This will open a browser for authentication."
echo "If running on a headless server, run this command on your local machine:"
echo "  cloudflared tunnel login"
echo "Then copy the cert.pem file to /root/.cloudflared/cert.pem on this server"
echo ""
read -p "Press Enter to continue with authentication..."

cloudflared tunnel login

# Create tunnel
TUNNEL_NAME="ml-train-server"
echo ""
echo "Creating tunnel: ${TUNNEL_NAME}"

if cloudflared tunnel list | grep -q "${TUNNEL_NAME}"; then
    echo "Tunnel ${TUNNEL_NAME} already exists"
    TUNNEL_ID=$(cloudflared tunnel list | grep "${TUNNEL_NAME}" | awk '{print $1}')
else
    cloudflared tunnel create ${TUNNEL_NAME}
    TUNNEL_ID=$(cloudflared tunnel list | grep "${TUNNEL_NAME}" | awk '{print $1}')
fi

echo "Tunnel ID: ${TUNNEL_ID}"

# Step 3: Configure tunnel
echo ""
echo "=== Step 3: Configuring tunnel ==="
echo "Domain: ${DOMAIN}"
echo "Users: ${USERS}"
echo ""

# Generate Cloudflare Tunnel configuration dynamically
cat > /root/.cloudflared/config.yml <<EOFCONFIG
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  # Infrastructure Services
  - hostname: health.${DOMAIN}
    service: http://localhost:80

  - hostname: prometheus.${DOMAIN}
    service: http://localhost:80

  - hostname: grafana.${DOMAIN}
    service: http://localhost:80

  - hostname: tensorboard.${DOMAIN}
    service: http://localhost:80

  - hostname: files.${DOMAIN}
    service: http://localhost:80

  - hostname: logs.${DOMAIN}
    service: http://localhost:80

  - hostname: portainer.${DOMAIN}
    service: http://localhost:80
EOFCONFIG

# Add per-user services dynamically
USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    cat >> /root/.cloudflared/config.yml <<EOFUSER

  # ${USERNAME} services
  - hostname: ${USERNAME}-desktop.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}-code.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}-jupyter.${DOMAIN}
    service: http://localhost:80
EOFUSER

    USER_INDEX=$((USER_INDEX + 1))
done

# Add catch-all rule
cat >> /root/.cloudflared/config.yml <<EOFCATCH

  # Catch-all rule
  - service: http_status:404
EOFCATCH

echo "Tunnel configuration created"

# Step 4: Route DNS to tunnel
echo ""
echo "=== Step 4: Routing DNS ==="

cloudflared tunnel route dns ${TUNNEL_NAME} "*.${DOMAIN}"

echo "DNS routed for *.${DOMAIN}"

# Step 5: Install as service
echo ""
echo "=== Step 5: Installing tunnel as systemd service ==="

cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared

echo "Cloudflare Tunnel service installed and started"

# Step 6: Display status
echo ""
echo "=== Cloudflare Tunnel Setup Complete ==="
echo ""
echo "Tunnel Name: ${TUNNEL_NAME}"
echo "Tunnel ID: ${TUNNEL_ID}"
echo "Domain: ${DOMAIN}"
echo ""
echo "Status:"
systemctl status cloudflared --no-pager
echo ""
echo "Configured services:"
echo "  https://health.${DOMAIN} → Netdata"
echo "  https://prometheus.${DOMAIN} → Prometheus"
echo "  https://grafana.${DOMAIN} → Grafana"
echo "  https://tensorboard.${DOMAIN} → TensorBoard"
echo "  https://files.${DOMAIN} → FileBrowser"
echo "  https://logs.${DOMAIN} → Dozzle"
echo "  https://portainer.${DOMAIN} → Portainer"
echo ""
echo "Per-user services (${USER_COUNT} users):"
for USERNAME in ${USER_ARRAY[@]}; do
    echo "  ${USERNAME}:"
    echo "    https://${USERNAME}-desktop.${DOMAIN} → NoMachine Web Desktop"
    echo "    https://${USERNAME}-code.${DOMAIN} → VS Code"
    echo "    https://${USERNAME}-jupyter.${DOMAIN} → Jupyter"
done
echo ""
echo "Note: All users share TensorBoard at https://tensorboard.${DOMAIN}"
echo "      Each user has their own directory: /shared/tensorboard/\${username}/"
echo ""
echo "NoMachine client connections:"
echo "  Use NoMachine client to connect directly to ports 4000+ (best performance)"
echo ""
echo "Next steps:"
echo "  1. Configure Cloudflare Access at: https://one.dash.cloudflare.com/"
echo "  2. Set up Google Workspace authentication"
echo "  3. Create access policies for each service"
echo "  4. Enable 2FA enforcement"
echo ""
