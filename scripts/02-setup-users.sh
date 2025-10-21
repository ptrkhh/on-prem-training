#!/bin/bash
set -euo pipefail

# ML Training Server - User Account Setup Script
# Creates user accounts from config.sh

echo "=== ML Training Server User Setup ==="

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

# Check storage is mounted
if ! mountpoint -q ${MOUNT_POINT}; then
    echo "ERROR: ${MOUNT_POINT} is not mounted. Run 01-setup-storage.sh first."
    exit 1
fi

echo "Creating ${USER_COUNT} user accounts..."
echo ""

USER_INDEX=0
for USERNAME in ${USER_ARRAY[@]}; do
    UID=$((FIRST_UID + USER_INDEX))

    echo "Setting up user: ${USERNAME} (UID: ${UID})"

    # Create user if doesn't exist
    if id "${USERNAME}" &>/dev/null; then
        echo "  User ${USERNAME} already exists, skipping creation"
    else
        # Create user with specific UID
        useradd -m -u ${UID} -s /bin/bash -d ${MOUNT_POINT}/homes/${USERNAME} ${USERNAME}
        echo "  Created user ${USERNAME}"
    fi


    # Set initial password (prompt)
    echo "  Setting password for ${USERNAME}:"
    passwd ${USERNAME}

    # Create home directory on BTRFS storage
    mkdir -p ${MOUNT_POINT}/homes/${USERNAME}
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/homes/${USERNAME}
    chmod 700 ${MOUNT_POINT}/homes/${USERNAME}

    # Create workspace directory
    mkdir -p ${MOUNT_POINT}/workspaces/${USERNAME}
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/workspaces/${USERNAME}
    chmod 755 ${MOUNT_POINT}/workspaces/${USERNAME}

    # Create docker-volumes directory
    mkdir -p ${MOUNT_POINT}/docker-volumes/${USERNAME}-state
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/docker-volumes/${USERNAME}-state
    chmod 755 ${MOUNT_POINT}/docker-volumes/${USERNAME}-state

    # Create tensorboard directory
    mkdir -p ${MOUNT_POINT}/shared/tensorboard/${USERNAME}
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/shared/tensorboard/${USERNAME}
    chmod 755 ${MOUNT_POINT}/shared/tensorboard/${USERNAME}

    # Create .ssh directory
    mkdir -p ${MOUNT_POINT}/homes/${USERNAME}/.ssh
    chmod 700 ${MOUNT_POINT}/homes/${USERNAME}/.ssh
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/homes/${USERNAME}/.ssh

    # Create placeholder for authorized_keys
    touch ${MOUNT_POINT}/homes/${USERNAME}/.ssh/authorized_keys
    chmod 600 ${MOUNT_POINT}/homes/${USERNAME}/.ssh/authorized_keys
    chown ${USERNAME}:${USERNAME} ${MOUNT_POINT}/homes/${USERNAME}/.ssh/authorized_keys

    echo "  Directory structure created for ${USERNAME}"
    echo ""

    USER_INDEX=$((USER_INDEX + 1))
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
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

echo "SSH configured for key-based authentication only"

# Restart SSH
systemctl restart sshd
echo "SSH service restarted"

# Create user quota monitoring script
echo ""
echo "Setting up disk quota monitoring..."

mkdir -p /opt/scripts/monitoring

cat > /opt/scripts/monitoring/check-user-quotas.sh <<'EOF'
#!/bin/bash
# Check user disk usage across home, workspace, and docker-volumes
# Sends alerts when users exceed quota thresholds

MOUNT_POINT="${MOUNT_POINT}"
QUOTA_LIMIT_GB=${USER_QUOTA_GB}
QUOTA_WARNING_PERCENT=${USER_QUOTA_WARNING_PERCENT}
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Convert GB to bytes for comparison
QUOTA_LIMIT_BYTES=\$((QUOTA_LIMIT_GB * 1024 * 1024 * 1024))
QUOTA_WARNING_BYTES=\$(awk "BEGIN {printf \"%.0f\", ${QUOTA_LIMIT_BYTES} * ${QUOTA_WARNING_PERCENT} / 100.0}")

echo "=== User Quota Check: \$(date) ==="
echo ""

for user_dir in \${MOUNT_POINT}/homes/*; do
    if [[ -d "\${user_dir}" ]]; then
        USER=\$(basename \${user_dir})

        # Calculate usage across all three directories
        HOME_USAGE=0
        WORKSPACE_USAGE=0
        DOCKER_USAGE=0

        if [[ -d "\${MOUNT_POINT}/homes/\${USER}" ]]; then
            HOME_USAGE=\$(du -sb "\${MOUNT_POINT}/homes/\${USER}" 2>/dev/null | cut -f1 || echo 0)
        fi

        if [[ -d "\${MOUNT_POINT}/workspaces/\${USER}" ]]; then
            WORKSPACE_USAGE=\$(du -sb "\${MOUNT_POINT}/workspaces/\${USER}" 2>/dev/null | cut -f1 || echo 0)
        fi

        if [[ -d "\${MOUNT_POINT}/docker-volumes/\${USER}-state" ]]; then
            DOCKER_USAGE=\$(du -sb "\${MOUNT_POINT}/docker-volumes/\${USER}-state" 2>/dev/null | cut -f1 || echo 0)
        fi

        # Total usage
        TOTAL_USAGE=\$((HOME_USAGE + WORKSPACE_USAGE + DOCKER_USAGE))

        # Convert to human-readable
        TOTAL_GB=\$(awk "BEGIN {printf \"%.2f\", \${TOTAL_USAGE} / 1024 / 1024 / 1024}")
        HOME_GB=\$(awk "BEGIN {printf \"%.2f\", \${HOME_USAGE} / 1024 / 1024 / 1024}")
        WORKSPACE_GB=\$(awk "BEGIN {printf \"%.2f\", \${WORKSPACE_USAGE} / 1024 / 1024 / 1024}")
        DOCKER_GB=\$(awk "BEGIN {printf \"%.2f\", \${DOCKER_USAGE} / 1024 / 1024 / 1024}")
        PERCENT=\$(awk "BEGIN {printf \"%.1f\", \${TOTAL_USAGE} * 100.0 / \${QUOTA_LIMIT_BYTES}}")

        echo "User: \${USER}"
        echo "  Total: \${TOTAL_GB}GB / \${QUOTA_LIMIT_GB}GB (\${PERCENT}%)"
        echo "  Breakdown:"
        echo "    - Home:      \${HOME_GB}GB"
        echo "    - Workspace: \${WORKSPACE_GB}GB"
        echo "    - Docker:    \${DOCKER_GB}GB"

        # Check if exceeded quota
        if [[ \${TOTAL_USAGE} -gt \${QUOTA_LIMIT_BYTES} ]]; then
            OVER_GB=\$(awk "BEGIN {printf \"%.2f\", (\${TOTAL_USAGE} - \${QUOTA_LIMIT_BYTES}) / 1024 / 1024 / 1024}")
            MESSAGE="⚠️ User \${USER} has EXCEEDED quota: \${TOTAL_GB}GB / \${QUOTA_LIMIT_GB}GB (over by \${OVER_GB}GB)"
            echo "  STATUS: ⚠️ OVER QUOTA by \${OVER_GB}GB"

            # Send alert
            if [[ -x "\${ALERT_SCRIPT}" ]]; then
                \${ALERT_SCRIPT} "warning" "\${MESSAGE}"
            fi

        # Check if approaching quota (warning threshold)
        elif [[ \${TOTAL_USAGE} -gt \${QUOTA_WARNING_BYTES} ]]; then
            MESSAGE="User \${USER} approaching quota: \${TOTAL_GB}GB / \${QUOTA_LIMIT_GB}GB (\${PERCENT}%)"
            echo "  STATUS: ⚠️ WARNING (>\${QUOTA_WARNING_PERCENT}%)"

            # Send warning (less urgent)
            if [[ -x "\${ALERT_SCRIPT}" ]]; then
                \${ALERT_SCRIPT} "info" "\${MESSAGE}"
            fi
        else
            echo "  STATUS: ✅ OK"
        fi

        echo ""
    fi
done

echo "=== Quota Check Complete ==="
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
echo "Created users: ${USERS}"
echo ""
echo "IMPORTANT: Add SSH public keys for each user:"
for USERNAME in ${USER_ARRAY[@]}; do
    echo "  ${MOUNT_POINT}/homes/${USERNAME}/.ssh/authorized_keys"
done
echo ""
echo "Users can access the server via:"
echo "  - SSH: ssh <user>@<server-ip> -p 2222 (or 2223, 2224, etc.)"
echo "  - NoMachine: Download client from https://nomachine.com/"
echo "    - Connect to ports 4000 (alice), 4001 (bob), etc."
echo ""
echo "Next steps:"
echo "  1. Add SSH keys for each user"
echo "  2. Test SSH login: ssh alice@localhost"
echo "  3. Run 03-setup-docker.sh to install Docker"
echo ""
