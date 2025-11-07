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

# Validate USERS is not empty
if [[ -z "${USERS}" ]]; then
    echo "ERROR: USERS variable is empty in config.sh"
    exit 1
fi

# Convert users string to array
USER_ARRAY=(${USERS})
USER_COUNT=${#USER_ARRAY[@]}

# Validate array has at least one element
if [[ ${USER_COUNT} -eq 0 ]]; then
    echo "ERROR: USERS array is empty after parsing"
    exit 1
fi

# Check storage is mounted
if ! mountpoint -q "${MOUNT_POINT}"; then
    echo "ERROR: ${MOUNT_POINT} is not mounted. Run 01-setup-storage.sh first."
    exit 1
fi

# Validate BTRFS filesystem with expected mount options
echo "Validating BTRFS mount..."
MOUNT_INFO=$(mount | grep "${MOUNT_POINT}" | grep btrfs)
if [[ -z "${MOUNT_INFO}" ]]; then
    echo "ERROR: ${MOUNT_POINT} is not mounted as BTRFS filesystem"
    echo "Please run 01-setup-storage.sh and reboot before continuing."
    exit 1
fi

# Check if expected mount options are present
if ! echo "${MOUNT_INFO}" | grep -q "compress"; then
    echo "WARNING: ${MOUNT_POINT} is not mounted with compression enabled"
    echo "Expected mount options may be missing. Did you reboot after running 01-setup-storage.sh?"
fi

# Verify mount is from fstab (not temporary)
if ! grep -q "^[^#].*${MOUNT_POINT}.*btrfs" /etc/fstab; then
    echo "WARNING: ${MOUNT_POINT} not found in /etc/fstab"
    echo "Mount may not persist after reboot. Please check 01-setup-storage.sh setup."
fi

echo "✓ BTRFS filesystem validation passed"

# Validate all required directories exist before creating users
echo "Validating required directories..."
if [[ ! -d "${MOUNT_POINT}/shared" ]]; then
    echo "ERROR: ${MOUNT_POINT}/shared does not exist!"
    echo "Please run 01-setup-storage.sh first, then 02-setup-gdrive-shared.sh to mount the required Google Drive Shared Drive."
    exit 1
fi

if [[ ! -d "${MOUNT_POINT}/cache" ]]; then
    echo "ERROR: ${MOUNT_POINT}/cache does not exist!"
    echo "Please run 03-setup-shared-caches.sh first."
    exit 1
fi

echo "Creating ${USER_COUNT} user accounts..."
echo ""

# Validate USER_DEFAULT_PASSWORD is set
if [[ -z "${USER_DEFAULT_PASSWORD:-}" ]]; then
    echo "ERROR: USER_DEFAULT_PASSWORD is not set in config.sh"
    exit 1
fi

# Resolve supplementary groups
USER_GROUPS_ARRAY=()
USER_GROUPS_VALID=()
USER_GROUPS_MISSING=()
USER_GROUPS_VALID_CSV=""

if [[ -n "${USER_GROUPS:-}" ]]; then
    # Split USER_GROUPS on whitespace
    read -r -a USER_GROUPS_ARRAY <<< "${USER_GROUPS}"

    for GROUP in "${USER_GROUPS_ARRAY[@]}"; do
        [[ -z "${GROUP}" ]] && continue

        if getent group "${GROUP}" > /dev/null 2>&1; then
            USER_GROUPS_VALID+=("${GROUP}")
        else
            USER_GROUPS_MISSING+=("${GROUP}")
        fi
    done

    if [[ ${#USER_GROUPS_VALID[@]} -gt 0 ]]; then
        USER_GROUPS_VALID_CSV=$(IFS=,; echo "${USER_GROUPS_VALID[*]}")
    fi
else
    echo "WARNING: USER_GROUPS is empty in config.sh; users will not receive supplementary groups."
fi

if [[ ${#USER_GROUPS_MISSING[@]} -gt 0 ]]; then
    echo "WARNING: The following groups from USER_GROUPS do not exist and will be skipped: ${USER_GROUPS_MISSING[*]}"
fi

USER_INDEX=0
for USERNAME in "${USER_ARRAY[@]}"; do
    UID=$((FIRST_UID + USER_INDEX))

    echo "Setting up user: ${USERNAME} (UID: ${UID})"

    # Create user if doesn't exist
    if id "${USERNAME}" &>/dev/null; then
        echo "  User ${USERNAME} already exists, skipping creation"

        # Verify existing user has correct UID
        EXISTING_UID=$(id -u "${USERNAME}")
        if [[ "${EXISTING_UID}" -ne "${UID}" ]]; then
            echo "  ⚠ WARNING: User ${USERNAME} has UID ${EXISTING_UID}, expected ${UID}"
            echo "    This may cause permission issues. Consider:"
            echo "    1. Using the existing UID (update FIRST_UID in config.sh)"
            echo "    2. Deleting and recreating the user: userdel ${USERNAME} && re-run script"
            echo "    3. Manually changing the UID: usermod -u ${UID} ${USERNAME}"
        else
            echo "  ✓ User ${USERNAME} has correct UID: ${UID}"
        fi
    else
        # Create user with specific UID
        useradd -m -u ${UID} -s /bin/bash -d ${MOUNT_POINT}/homes/${USERNAME} ${USERNAME}
        echo "  Created user ${USERNAME}"
    fi

    # Set password from config
    # Use heredoc to avoid command-line exposure
    chpasswd <<EOF
${USERNAME}:${USER_DEFAULT_PASSWORD}
EOF
    echo "  Password set from USER_DEFAULT_PASSWORD"

    if [[ -n "${USER_GROUPS_VALID_CSV}" ]]; then
        if usermod -aG "${USER_GROUPS_VALID_CSV}" "${USERNAME}"; then
            echo "  Added to supplementary groups: ${USER_GROUPS_VALID[*]}"
        else
            echo "  WARNING: Failed to update supplementary groups for ${USERNAME}"
        fi
    else
        echo "  No supplementary groups configured for ${USERNAME}"
    fi

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

# Update sshd_config for security (keep password auth enabled until SSH keys are added)
cat > /etc/ssh/sshd_config.d/ml-train-server.conf <<EOF
# ML Training Server SSH Configuration
# Allow root login with SSH keys only (no password-based root login)
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

echo "SSH configured (password authentication enabled until SSH keys are added)"
echo ""
echo "⚠️  SECURITY REMINDER: SSH password authentication is currently ENABLED"
echo "   Add SSH keys for all users, then run: /root/disable-ssh-password-auth.sh"
echo "   Do this within 24 hours of setup for security"

# Create script to disable password authentication after SSH keys are verified
cat > /root/disable-ssh-password-auth.sh <<EOFSCRIPT
#!/bin/bash
# Disable password authentication after verifying SSH keys are set up

echo "=== Disable SSH Password Authentication ==="
echo ""
echo "This will disable password authentication and require SSH keys."
echo ""

# Check if all users have SSH keys
for user_home in ${MOUNT_POINT}/homes/*; do
    if [[ -d "\${user_home}" ]]; then
        USERNAME=\$(basename \${user_home})
        KEY_FILE="\${user_home}/.ssh/authorized_keys"

        if [[ ! -s "\${KEY_FILE}" ]]; then
            echo "⚠️  WARNING: User \${USERNAME} has no SSH keys in \${KEY_FILE}"
            echo "   Add SSH keys before proceeding to avoid lockout!"
            echo ""
            read -p "Continue anyway? (yes/no): " confirm
            if [[ "\$confirm" != "yes" ]]; then
                echo "Aborted."
                exit 1
            fi
        else
            echo "✓ User \${USERNAME} has SSH keys configured"
        fi
    fi
done

echo ""
echo "Disabling password authentication..."

# Update SSH config
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/ml-train-server.conf

# Restart SSH
systemctl restart sshd

echo "✓ Password authentication disabled"
echo "✓ SSH now requires key-based authentication only"
EOFSCRIPT

chmod +x /root/disable-ssh-password-auth.sh

echo "Created script: /root/disable-ssh-password-auth.sh"
echo "Run this script after adding SSH keys to disable password authentication"

# Restart SSH
systemctl restart sshd
echo "SSH service restarted"

# Create user quota monitoring script
echo ""
echo "Setting up disk quota monitoring..."

mkdir -p /opt/scripts/monitoring

cat > /opt/scripts/monitoring/check-user-quotas.sh <<EOF
#!/bin/bash
# Check user disk usage across home, workspace, and docker-volumes
# Sends alerts when users exceed quota thresholds

MOUNT_POINT="${MOUNT_POINT}"
QUOTA_LIMIT_GB=${USER_QUOTA_GB}
QUOTA_WARNING_PERCENT=${USER_QUOTA_WARNING_PERCENT}
ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Convert GB to bytes for comparison
QUOTA_LIMIT_BYTES=\$((QUOTA_LIMIT_GB * 1024 * 1024 * 1024))
QUOTA_WARNING_BYTES=\$(awk "BEGIN {printf \"%.0f\", \${QUOTA_LIMIT_BYTES} * \${QUOTA_WARNING_PERCENT} / 100.0}")

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

        # Convert to human-readable and calculate total (using awk to avoid integer overflow)
        TOTAL_GB=\$(awk "BEGIN {printf \"%.2f\", (\${HOME_USAGE} + \${WORKSPACE_USAGE} + \${DOCKER_USAGE}) / 1024 / 1024 / 1024}")
        HOME_GB=\$(awk "BEGIN {printf \"%.2f\", \${HOME_USAGE} / 1024 / 1024 / 1024}")
        WORKSPACE_GB=\$(awk "BEGIN {printf \"%.2f\", \${WORKSPACE_USAGE} / 1024 / 1024 / 1024}")
        DOCKER_GB=\$(awk "BEGIN {printf \"%.2f\", \${DOCKER_USAGE} / 1024 / 1024 / 1024}")
        PERCENT=\$(awk "BEGIN {printf \"%.1f\", (\${HOME_USAGE} + \${WORKSPACE_USAGE} + \${DOCKER_USAGE}) * 100.0 / \${QUOTA_LIMIT_BYTES}}")
        TOTAL_USAGE_BYTES=\$(awk "BEGIN {printf \"%.0f\", \${HOME_USAGE} + \${WORKSPACE_USAGE} + \${DOCKER_USAGE}}")

        echo "User: \${USER}"
        echo "  Total: \${TOTAL_GB}GB / \${QUOTA_LIMIT_GB}GB (\${PERCENT}%)"
        echo "  Breakdown:"
        echo "    - Home:      \${HOME_GB}GB"
        echo "    - Workspace: \${WORKSPACE_GB}GB"
        echo "    - Docker:    \${DOCKER_GB}GB"

        # Check if exceeded quota
        if (( \$(awk "BEGIN {print (\${TOTAL_USAGE_BYTES} > \${QUOTA_LIMIT_BYTES})}") )); then
            OVER_GB=\$(awk "BEGIN {printf \"%.2f\", (\${TOTAL_USAGE_BYTES} - \${QUOTA_LIMIT_BYTES}) / 1024 / 1024 / 1024}")
            MESSAGE="⚠️ User \${USER} has EXCEEDED quota: \${TOTAL_GB}GB / \${QUOTA_LIMIT_GB}GB (over by \${OVER_GB}GB)"
            echo "  STATUS: ⚠️ OVER QUOTA by \${OVER_GB}GB"

            # Send alert
            if [[ -x "\${ALERT_SCRIPT}" ]]; then
                \${ALERT_SCRIPT} "warning" "\${MESSAGE}"
            fi

        # Check if approaching quota (warning threshold)
        elif (( \$(awk "BEGIN {print (\${TOTAL_USAGE_BYTES} > \${QUOTA_WARNING_BYTES})}") )); then
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
for USERNAME in "${USER_ARRAY[@]}"; do
    echo "  ${MOUNT_POINT}/homes/${USERNAME}/.ssh/authorized_keys"
done
echo ""
echo "Users can access the server via:"
echo "  - SSH: ssh <user>@<server-ip> -p 2222 (or 2223, 2224, etc.)"
echo "  - Web Desktop (noVNC): http://<user>-desktop.<domain> or http://<user>.<domain>"
echo "  - Guacamole (Web Gateway): http://guacamole.<domain> or http://remote.<domain>"
echo "  - Kasm Workspaces: http://kasm.<domain>"
echo "  - Direct VNC: <server-ip>:5900, 5901, 5902, etc."
echo "  - Direct RDP: <server-ip>:3389, 3390, 3391, etc."
echo ""
echo "Next steps:"
echo "  1. Add SSH keys for each user"
echo "  2. Test SSH login: ssh alice@localhost"
echo "  3. Run 05-setup-docker.sh to install Docker"
echo ""
