#!/bin/bash
set -euo pipefail

# ML Training Server - Cloudflare Tunnel Setup

echo "=== Cloudflare Tunnel Setup ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

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

read -p "Enter your domain (e.g., example.com): " DOMAIN

cat > /root/.cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  # Guacamole - Remote Desktop
  - hostname: remote.${DOMAIN}
    service: http://localhost:8080

  # Netdata - System Monitoring
  - hostname: health.${DOMAIN}
    service: http://localhost:19999

  # Prometheus - Metrics Backend
  - hostname: metrics-backend.${DOMAIN}
    service: http://localhost:9090

  # Grafana - Metrics Dashboard
  - hostname: metrics.${DOMAIN}
    service: http://localhost:3000

  # TensorBoard - Shared Training Logs
  - hostname: tensorboard.${DOMAIN}
    service: http://localhost:6006

  # FileBrowser
  - hostname: files.${DOMAIN}
    service: http://localhost:8081

  # Dozzle - Container Logs
  - hostname: logs.${DOMAIN}
    service: http://localhost:8082

  # Portainer
  - hostname: portainer.${DOMAIN}
    service: http://localhost:9000

  # Code-server instances
  - hostname: alice-code.${DOMAIN}
    service: http://localhost:8443

  - hostname: bob-code.${DOMAIN}
    service: http://localhost:8444

  - hostname: charlie-code.${DOMAIN}
    service: http://localhost:8445

  - hostname: dave-code.${DOMAIN}
    service: http://localhost:8446

  - hostname: eve-code.${DOMAIN}
    service: http://localhost:8447

  # Jupyter instances
  - hostname: jupyter-alice.${DOMAIN}
    service: http://localhost:8888

  - hostname: jupyter-bob.${DOMAIN}
    service: http://localhost:8889

  - hostname: jupyter-charlie.${DOMAIN}
    service: http://localhost:8890

  - hostname: jupyter-dave.${DOMAIN}
    service: http://localhost:8891

  - hostname: jupyter-eve.${DOMAIN}
    service: http://localhost:8892

  # Catch-all rule
  - service: http_status:404
EOF

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
echo "  https://remote.${DOMAIN} → Guacamole"
echo "  https://health.${DOMAIN} → Netdata"
echo "  https://metrics.${DOMAIN} → Grafana"
echo "  https://tensorboard.${DOMAIN} → TensorBoard"
echo "  https://files.${DOMAIN} → FileBrowser"
echo "  https://logs.${DOMAIN} → Dozzle"
echo "  https://portainer.${DOMAIN} → Portainer"
echo "  https://alice-code.${DOMAIN} → VS Code (Alice)"
echo "  https://jupyter-alice.${DOMAIN} → Jupyter (Alice)"
echo "  ... (repeat for bob, charlie, dave, eve)"
echo ""
echo "Next steps:"
echo "  1. Configure Cloudflare Access at: https://one.dash.cloudflare.com/"
echo "  2. Set up Google Workspace authentication"
echo "  3. Create access policies for each service"
echo "  4. Enable 2FA enforcement"
echo ""
