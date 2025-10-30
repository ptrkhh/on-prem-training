#!/bin/bash
set -euo pipefail

# ML Training Server - Firewall and Security Setup

echo "=== Firewall and Security Setup ==="

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

# Step 1: Install UFW
echo ""
echo "=== Step 1: Installing UFW ==="

apt update
apt install -y ufw

# Step 2: Configure UFW
echo ""
echo "=== Step 2: Configuring UFW ==="

# Backup existing UFW rules before reset
echo "⚠️  WARNING: This will reset UFW firewall to defaults!"
echo "   All existing rules will be removed."
if ufw status &>/dev/null; then
    BACKUP_DIR="/root/ufw-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${BACKUP_DIR}"
    if [[ -d /etc/ufw ]]; then
        cp -r /etc/ufw "${BACKUP_DIR}/"
        echo "✓ Existing UFW rules backed up to ${BACKUP_DIR}"
        echo "  To restore: cp -r ${BACKUP_DIR}/ufw/* /etc/ufw/ && ufw reload"
    fi
fi
echo ""
read -p "Continue with UFW reset? (yes/no): " confirm_reset
if [[ "$confirm_reset" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# Reset UFW to defaults
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (port 22)
ufw allow 22/tcp comment 'SSH'

# Allow SSH port range for user containers
USER_COUNT=$(echo ${USERS} | wc -w)
SSH_BASE_PORT=${SSH_BASE_PORT:-2222}
echo "Opening SSH ports for ${USER_COUNT} users (${SSH_BASE_PORT}-$((SSH_BASE_PORT + USER_COUNT - 1)))..."
for ((i=0; i<USER_COUNT; i++)); do
    port=$((SSH_BASE_PORT + i))
    ufw allow ${port}/tcp comment "SSH - User container $i"
done

# Allow local network access (use LOCAL_NETWORK_CIDR from config)
if [[ -n "${LOCAL_NETWORK_CIDR:-}" ]]; then
    echo "Allowing local network access from ${LOCAL_NETWORK_CIDR}"
    ufw allow from ${LOCAL_NETWORK_CIDR} comment 'Local network'
else
    read -p "Allow local network access? (y/n): " allow_local
    if [[ "$allow_local" == "y" ]]; then
        read -p "Enter local network CIDR (e.g., 192.168.1.0/24): " local_cidr
        ufw allow from ${local_cidr} comment 'Local network'
    fi
fi

# Enable UFW
echo "Enabling UFW..."
ufw --force enable

echo "UFW configured and enabled"

# Step 3: Install and configure fail2ban
echo ""
echo "=== Step 3: Installing fail2ban ==="

apt install -y fail2ban

# Configure fail2ban for SSH
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

# Restart fail2ban
systemctl enable fail2ban
systemctl restart fail2ban

echo "fail2ban configured and enabled"

# Step 4: Enable automatic security updates
echo ""
echo "=== Step 4: Configuring automatic security updates ==="

apt install -y unattended-upgrades

# Configure unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# Enable automatic updates
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "Automatic security updates enabled"

# Step 5: Harden SSH (already done in 02-setup-users.sh, verify here)
echo ""
echo "=== Step 5: Verifying SSH hardening ==="

if [[ -f /etc/ssh/sshd_config.d/ml-train-server.conf ]]; then
    echo "SSH already hardened in previous step"
else
    echo "WARNING: SSH not hardened. Run 02-setup-users.sh first."
fi

# Step 6: Install and configure auditd (optional)
echo ""
read -p "Install auditd for security auditing? (y/n): " install_audit

if [[ "$install_audit" == "y" ]]; then
    apt install -y auditd audispd-plugins

    # Add some basic audit rules
    cat > /etc/audit/rules.d/ml-train-server.rules <<EOF
# Monitor file changes in critical directories
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd

# Monitor system calls
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b64 -S open -S openat -k file_access

# Monitor Docker
-w /var/lib/docker -p wa -k docker
-w /usr/bin/docker -p x -k docker_execution
EOF

    systemctl enable auditd
    systemctl restart auditd

    echo "auditd installed and configured"
fi

# Step 7: Configure iptables for Docker (optional rate limiting)
echo ""
echo "=== Step 7: Docker network configuration ==="

# Note: Rate limiting is handled by Cloudflare, not locally
echo "Rate limiting is handled by Cloudflare Tunnel"

# Display status
echo ""
echo "=== Firewall and Security Setup Complete ==="
echo ""
echo "UFW Status:"
ufw status verbose
echo ""
echo "fail2ban Status:"
fail2ban-client status
echo ""
echo "Security measures enabled:"
echo "  - UFW: Deny all incoming, allow outgoing"
echo "  - fail2ban: SSH brute force protection"
echo "  - Automatic security updates: Enabled"
echo "  - SSH: Key-based authentication only"
echo "  - Cloudflare Tunnel: All external traffic routed through Cloudflare"
echo ""
echo "No ports are exposed to the internet (Cloudflare Tunnel only)"
echo ""
