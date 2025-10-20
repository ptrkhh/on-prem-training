#!/bin/bash
set -euo pipefail

# ML Training Server - User Account Setup Script
# Creates 5 user accounts: alice, bob, charlie, dave, eve

echo "=== ML Training Server User Setup ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Configuration
USERS=("alice" "bob" "charlie" "dave" "eve")
UIDS=(1000 1001 1002 1003 1004)
MOUNT_POINT="/mnt/storage"

# Check storage is mounted
if ! mountpoint -q ${MOUNT_POINT}; then
    echo "ERROR: ${MOUNT_POINT} is not mounted. Run 01-setup-storage.sh first."
    exit 1
fi

echo "Creating 5 user accounts..."
echo ""

for i in "${!USERS[@]}"; do
    USER="${USERS[$i]}"
    UID="${UIDS[$i]}"

    echo "Setting up user: ${USER} (UID: ${UID})"

    # Create user if doesn't exist
    if id "${USER}" &>/dev/null; then
        echo "  User ${USER} already exists, skipping creation"
    else
        # Create user with specific UID
        useradd -m -u ${UID} -s /bin/bash -d ${MOUNT_POINT}/homes/${USER} ${USER}
        echo "  Created user ${USER}"
    fi

    # Add to docker and sudo groups
    usermod -aG docker,sudo ${USER}

    # Set initial password (prompt)
    echo "  Setting password for ${USER}:"
    passwd ${USER}

    # Create home directory on BTRFS storage
    mkdir -p ${MOUNT_POINT}/homes/${USER}
    chown ${USER}:${USER} ${MOUNT_POINT}/homes/${USER}
    chmod 700 ${MOUNT_POINT}/homes/${USER}

    # Create workspace directory
    mkdir -p ${MOUNT_POINT}/workspaces/${USER}
    chown ${USER}:${USER} ${MOUNT_POINT}/workspaces/${USER}
    chmod 755 ${MOUNT_POINT}/workspaces/${USER}

    # Create docker-volumes directory
    mkdir -p ${MOUNT_POINT}/docker-volumes/${USER}-state
    chown ${USER}:${USER} ${MOUNT_POINT}/docker-volumes/${USER}-state
    chmod 755 ${MOUNT_POINT}/docker-volumes/${USER}-state

    # Create tensorboard directory
    mkdir -p ${MOUNT_POINT}/shared/tensorboard/${USER}
    chown ${USER}:${USER} ${MOUNT_POINT}/shared/tensorboard/${USER}
    chmod 755 ${MOUNT_POINT}/shared/tensorboard/${USER}

    # Create .ssh directory
    mkdir -p ${MOUNT_POINT}/homes/${USER}/.ssh
    chmod 700 ${MOUNT_POINT}/homes/${USER}/.ssh
    chown ${USER}:${USER} ${MOUNT_POINT}/homes/${USER}/.ssh

    # Create placeholder for authorized_keys
    touch ${MOUNT_POINT}/homes/${USER}/.ssh/authorized_keys
    chmod 600 ${MOUNT_POINT}/homes/${USER}/.ssh/authorized_keys
    chown ${USER}:${USER} ${MOUNT_POINT}/homes/${USER}/.ssh/authorized_keys

    echo "  Directory structure created for ${USER}"
    echo ""
done

# Configure SSH
echo "Configuring SSH..."

# Backup sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

# Update sshd_config for security
cat > /etc/ssh/sshd_config.d/ml-train-server.conf <<EOF
# ML Training Server SSH Configuration
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

echo "SSH configured for key-based authentication"

# Install Google Authenticator for 2FA (optional)
echo ""
read -p "Install Google Authenticator for 2FA? (y/n): " install_2fa
if [[ "$install_2fa" == "y" ]]; then
    apt install -y libpam-google-authenticator

    # Configure PAM for Google Authenticator
    if ! grep -q "pam_google_authenticator.so" /etc/pam.d/sshd; then
        echo "auth required pam_google_authenticator.so" >> /etc/pam.d/sshd
        echo "Google Authenticator PAM module added"
    fi

    echo ""
    echo "Users must run 'google-authenticator' to set up 2FA"
else
    echo "Skipping 2FA setup"
fi

# Restart SSH
systemctl restart sshd
echo "SSH service restarted"

# Create user quota monitoring script
echo ""
echo "Setting up disk quota monitoring..."

mkdir -p /opt/scripts/monitoring

cat > /opt/scripts/monitoring/check-user-quotas.sh <<'EOF'
#!/bin/bash
# Check user disk usage and send alerts

MOUNT_POINT="/mnt/storage"
QUOTA_LIMIT_TB=1
QUOTA_LIMIT_BYTES=$((QUOTA_LIMIT_TB * 1024 * 1024 * 1024 * 1024))
ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"

for user_dir in ${MOUNT_POINT}/homes/*; do
    if [[ -d "${user_dir}" ]]; then
        USER=$(basename ${user_dir})
        USAGE=$(du -sb ${user_dir} | cut -f1)
        USAGE_TB=$(echo "scale=2; ${USAGE} / 1024 / 1024 / 1024 / 1024" | bc)

        if [[ ${USAGE} -gt ${QUOTA_LIMIT_BYTES} ]]; then
            MESSAGE="User ${USER} has exceeded 1TB quota: ${USAGE_TB}TB used"
            echo "${MESSAGE}"

            # Send alert if script exists
            if [[ -x "${ALERT_SCRIPT}" ]]; then
                ${ALERT_SCRIPT} "warning" "${MESSAGE}"
            fi

            # Send email to user
            echo "${MESSAGE}" | mail -s "Disk Quota Warning" ${USER}@localhost
        fi
    fi
done
EOF

chmod +x /opt/scripts/monitoring/check-user-quotas.sh

# Add daily cron job for quota check
cat > /etc/cron.daily/check-user-quotas <<EOF
#!/bin/bash
/opt/scripts/monitoring/check-user-quotas.sh
EOF

chmod +x /etc/cron.daily/check-user-quotas

echo "Disk quota monitoring configured (daily check at 6:25 AM)"

# Display SSH key instructions
echo ""
echo "=== User Setup Complete ==="
echo ""
echo "Created users: ${USERS[*]}"
echo ""
echo "IMPORTANT: Add SSH public keys for each user:"
for USER in "${USERS[@]}"; do
    echo "  ${MOUNT_POINT}/homes/${USER}/.ssh/authorized_keys"
done
echo ""
echo "Users can access the server via:"
echo "  - SSH: ssh <user>@<server-ip>"
echo "  - X2Go: Install X2Go client and connect"
echo "  - Guacamole: https://remote.yourdomain.com (after Cloudflare setup)"
echo ""

if [[ "$install_2fa" == "y" ]]; then
    echo "2FA Setup:"
    echo "  Each user should run: google-authenticator"
    echo "  and scan the QR code with their authenticator app"
    echo ""
fi

echo "Next steps:"
echo "  1. Add SSH keys for each user"
echo "  2. Test SSH login: ssh alice@localhost"
echo "  3. Run 03-setup-docker.sh to install Docker"
echo ""
