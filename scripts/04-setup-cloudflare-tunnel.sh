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

# Generate Cloudflare Tunnel configuration (idempotent - regenerate entire file)
# Backup existing config if present
if [[ -f /root/.cloudflared/config.yml ]]; then
    echo "Backing up existing configuration..."
    cp /root/.cloudflared/config.yml /root/.cloudflared/config.yml.backup.$(date +%Y%m%d_%H%M%S)
fi

# Build the configuration file completely
CONFIG_CONTENT="tunnel: ${TUNNEL_ID}
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

  # Remote Desktop Gateways
  - hostname: guacamole.${DOMAIN}
    service: http://localhost:80

  - hostname: remote.${DOMAIN}
    service: http://localhost:80

  - hostname: kasm.${DOMAIN}
    service: http://localhost:80
"

# Add per-user services dynamically
for USERNAME in ${USER_ARRAY[@]}; do
    CONFIG_CONTENT="${CONFIG_CONTENT}
  # ${USERNAME} services
  - hostname: ${USERNAME}-desktop.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}-code.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}-jupyter.${DOMAIN}
    service: http://localhost:80

  - hostname: ${USERNAME}-tensorboard.${DOMAIN}
    service: http://localhost:80
"
done

# Add catch-all rule
CONFIG_CONTENT="${CONFIG_CONTENT}
  # Catch-all rule
  - service: http_status:404
"

# Write the complete configuration atomically
echo "${CONFIG_CONTENT}" > /root/.cloudflared/config.yml

echo "Tunnel configuration created"

# Step 4: Route DNS to tunnel
echo ""
echo "=== Step 4: Routing DNS ==="

# Check if route already exists (idempotent) - check by domain pattern, not tunnel name
EXISTING_ROUTE=$(cloudflared tunnel route dns list 2>/dev/null | awk -v domain="*.${DOMAIN}" '$0 ~ domain {print $1}' || echo "")
if [[ -n "${EXISTING_ROUTE}" ]]; then
    echo "DNS route for *.${DOMAIN} already exists (tunnel: ${EXISTING_ROUTE}), skipping..."
else
    cloudflared tunnel route dns ${TUNNEL_NAME} "*.${DOMAIN}"
    echo "DNS routed for *.${DOMAIN}"
fi

# Step 5: Install as service
echo ""
echo "=== Step 5: Installing tunnel as systemd service ==="

cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared

echo "Cloudflare Tunnel service installed and started"

# Verify tunnel connection
echo ""
echo "Waiting for tunnel to connect..."
for i in {1..30}; do
    if journalctl -u cloudflared -n 20 | grep -q "Connection .* registered"; then
        echo "✓ Tunnel connected successfully"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "⚠️  WARNING: Tunnel may not be connected. Check: journalctl -u cloudflared"
    fi
    sleep 1
done

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
echo "  https://tensorboard.${DOMAIN} → Shared TensorBoard"
echo "  https://files.${DOMAIN} → FileBrowser"
echo "  https://logs.${DOMAIN} → Dozzle"
echo "  https://portainer.${DOMAIN} → Portainer"
echo ""
echo "Remote Desktop Gateways:"
echo "  https://guacamole.${DOMAIN} → Apache Guacamole (primary)"
echo "  https://remote.${DOMAIN} → Apache Guacamole (alias)"
echo "  https://kasm.${DOMAIN} → Kasm Workspaces (alternative)"
echo ""
echo "Per-user services (${USER_COUNT} users):"
for USERNAME in ${USER_ARRAY[@]}; do
    echo "  ${USERNAME}:"
    echo "    https://${USERNAME}-desktop.${DOMAIN} → Desktop (noVNC)"
    echo "    https://${USERNAME}.${DOMAIN} → Desktop (short URL)"
    echo "    https://${USERNAME}-code.${DOMAIN} → VS Code"
    echo "    https://${USERNAME}-jupyter.${DOMAIN} → Jupyter"
    echo "    https://${USERNAME}-tensorboard.${DOMAIN} → Per-user TensorBoard"
done
echo ""
echo "Desktop Access:"
echo "  Primary: Apache Guacamole (https://guacamole.${DOMAIN})"
echo "    - Browser-based, no client needed"
echo "    - Select user desktop connection from list"
echo "    - Supports VNC and RDP protocols"
echo ""
echo "  Alternative: Kasm Workspaces (https://kasm.${DOMAIN})"
echo "    - Container streaming platform"
echo "    - Launch user workspace from dashboard"
echo ""
echo "  Direct connections (local network or via SSH tunnel):"
echo "    - VNC: ports ${VNC_BASE_PORT}+"
echo "    - RDP: ports ${RDP_BASE_PORT}+"
echo "    - noVNC (HTML5): ports ${NOVNC_BASE_PORT}+"
echo ""
echo "Next steps:"
echo "  1. Configure Cloudflare Access at: https://one.dash.cloudflare.com/"
echo "  2. Set up Google Workspace authentication"
echo "  3. Create access policies for each service"
echo "  4. Enable 2FA enforcement"
echo ""
