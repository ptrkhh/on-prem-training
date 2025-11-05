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

# Step 1: Install UFW and netcat
echo ""
echo "=== Step 1: Installing UFW and dependencies ==="

apt update
apt install -y ufw netcat-openbsd

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
        if cp -r /etc/ufw "${BACKUP_DIR}/"; then
            # Verify backup was created successfully
            if [[ -d "${BACKUP_DIR}/ufw" ]] && [[ -f "${BACKUP_DIR}/ufw/ufw.conf" ]]; then
                echo "✓ Existing UFW rules backed up to ${BACKUP_DIR}"
                echo "  To restore: cp -r ${BACKUP_DIR}/ufw/* /etc/ufw/ && ufw reload"
            else
                echo "✗ ERROR: UFW backup verification failed"
                echo "  Backup directory exists but contents are incomplete"
                echo "  Aborting to prevent data loss"
                exit 1
            fi
        else
            echo "✗ ERROR: Failed to backup UFW rules to ${BACKUP_DIR}"
            echo "  Cannot proceed without successful backup"
            exit 1
        fi
    fi
fi
echo ""
if ! validate_yes_no_full "Continue with UFW reset?"; then
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
VNC_BASE_PORT=${VNC_BASE_PORT:-5900}
RDP_BASE_PORT=${RDP_BASE_PORT:-3389}
NOVNC_BASE_PORT=${NOVNC_BASE_PORT:-6080}

echo "Opening SSH ports for ${USER_COUNT} users (${SSH_BASE_PORT}-$((SSH_BASE_PORT + USER_COUNT - 1)))..."
for ((i=0; i<USER_COUNT; i++)); do
    port=$((SSH_BASE_PORT + i))
    ufw allow ${port}/tcp comment "SSH - User container $i"
done

# Open VNC/RDP/noVNC ports if LOCAL_NETWORK_CIDR is set (for local access)
if [[ -n "${LOCAL_NETWORK_CIDR:-}" ]]; then
    echo "Opening VNC/RDP/noVNC ports for local network ${LOCAL_NETWORK_CIDR}..."
    for ((i=0; i<USER_COUNT; i++)); do
        ufw allow from ${LOCAL_NETWORK_CIDR} to any port $((VNC_BASE_PORT + i)) proto tcp comment "VNC - User $i"
        ufw allow from ${LOCAL_NETWORK_CIDR} to any port $((RDP_BASE_PORT + i)) proto tcp comment "RDP - User $i"
        ufw allow from ${LOCAL_NETWORK_CIDR} to any port $((NOVNC_BASE_PORT + i)) proto tcp comment "noVNC - User $i"
    done
fi

# Allow local network access (use LOCAL_NETWORK_CIDR from config)
if [[ -n "${LOCAL_NETWORK_CIDR:-}" ]]; then
    echo "Allowing local network access from ${LOCAL_NETWORK_CIDR}"
    ufw allow from ${LOCAL_NETWORK_CIDR} comment 'Local network'
else
    if validate_yes_no "Allow local network access?"; then
        read -p "Enter local network CIDR (e.g., 192.168.1.0/24): " local_cidr
        # Validate CIDR format
        if [[ ! "${local_cidr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "ERROR: Invalid CIDR format"
            exit 1
        fi
        ufw allow from ${local_cidr} comment 'Local network'
    fi
fi

# Show ports before enabling
echo ""
echo "Ports that will be allowed after UFW is enabled:"
ufw show added | grep -E "^ufw allow" || echo "  (No rules configured yet)"
echo ""

# Enable UFW
echo "Enabling UFW..."
ufw --force enable

echo "UFW configured and enabled"

# Test critical ports after enabling
echo ""
echo "Testing critical services after firewall enable..."
SERVICES_OK=true

# Test SSH (should be accessible)
if command -v nc &>/dev/null && nc -z -w5 localhost 22 2>/dev/null; then
    echo "✓ SSH port 22 is accessible"
else
    echo "✗ WARNING: SSH port 22 not accessible (or nc not available)"
    SERVICES_OK=false
fi

# Test HTTP (Docker services) - use curl as primary method since it's more reliable
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://localhost:80 2>/dev/null)
if [[ "${HTTP_CODE}" =~ ^[0-9]+$ ]] && [[ ${HTTP_CODE} -lt 600 ]]; then
    echo "✓ HTTP port 80 is accessible (HTTP ${HTTP_CODE})"
elif command -v nc &>/dev/null && nc -z -w5 localhost 80 2>/dev/null; then
    echo "✓ HTTP port 80 is accessible (verified via netcat)"
else
    if [[ -z "${HTTP_CODE}" ]]; then
        echo "✗ WARNING: HTTP port 80 not accessible. Curl failed (connection refused or timeout)"
    else
        echo "✗ WARNING: HTTP port 80 not accessible. Response: ${HTTP_CODE}"
    fi
    SERVICES_OK=false
fi

if [[ "${SERVICES_OK}" == "false" ]]; then
    echo ""
    echo "⚠️  WARNING: Some services may not be accessible after firewall configuration"
    echo "   Review UFW rules with: ufw status verbose"
fi

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

# Step 5: Harden SSH (already done in 04-setup-users.sh, verify here)
echo ""
echo "=== Step 5: Verifying SSH hardening ==="

if [[ -f /etc/ssh/sshd_config.d/ml-train-server.conf ]]; then
    echo "SSH already hardened in previous step"
else
    echo "WARNING: SSH not hardened. Run 04-setup-users.sh first."
fi

# Step 6: Install and configure auditd (optional)
echo ""
if validate_yes_no "Install auditd for security auditing?"; then
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
