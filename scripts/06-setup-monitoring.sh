#!/bin/bash
set -euo pipefail

# ML Training Server - Monitoring and Alerting Setup

echo "=== Monitoring and Alerting Setup ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

SCRIPTS_DIR="/opt/scripts/monitoring"

# Install required packages
echo "Installing required packages..."
apt update
apt install -y smartmontools bc jq curl mailutils

# Step 1: Create monitoring scripts directory
echo ""
echo "=== Step 1: Creating monitoring scripts ==="

mkdir -p ${SCRIPTS_DIR}

# Slack Alert Script
cat > ${SCRIPTS_DIR}/send-slack-alert.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Send alert to Slack
# Usage: send-slack-alert.sh <level> <message>
# Level: info, warning, critical

LEVEL="$1"
MESSAGE="$2"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

if [[ -z "${SLACK_WEBHOOK_URL}" ]] && [[ -f /root/.slack-webhook ]]; then
    SLACK_WEBHOOK_URL=$(cat /root/.slack-webhook)
fi

if [[ -z "${SLACK_WEBHOOK_URL}" ]]; then
    echo "No Slack webhook URL configured"
    echo "${LEVEL}: ${MESSAGE}"
    exit 0
fi

# Set color based on level
case "${LEVEL}" in
    info)
        COLOR="#36a64f"  # green
        EMOJI=":information_source:"
        ;;
    warning)
        COLOR="#ff9900"  # orange
        EMOJI=":warning:"
        ;;
    critical)
        COLOR="#ff0000"  # red
        EMOJI=":rotating_light:"
        ;;
    *)
        COLOR="#cccccc"  # gray
        EMOJI=":bell:"
        ;;
esac

# Send to Slack
curl -X POST "${SLACK_WEBHOOK_URL}" \
    -H 'Content-Type: application/json' \
    -d @- <<PAYLOAD
{
    "attachments": [{
        "color": "${COLOR}",
        "title": "${EMOJI} ML Train Server Alert",
        "text": "${MESSAGE}",
        "footer": "ML Training Server",
        "ts": $(date +%s)
    }]
}
PAYLOAD
EOF

chmod +x ${SCRIPTS_DIR}/send-slack-alert.sh

# SMART Monitoring Script
cat > ${SCRIPTS_DIR}/check-disk-smart.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"
DEVICES=("/dev/sda" "/dev/sdb" "/dev/sdc" "/dev/sdd" "/dev/nvme0n1")

for device in "${DEVICES[@]}"; do
    if [[ ! -b "${device}" ]]; then
        continue
    fi

    # Run SMART test
    if smartctl -H ${device} | grep -q "PASSED"; then
        echo "${device}: SMART status PASSED"
    else
        MESSAGE="CRITICAL: SMART test failed for ${device}!"
        echo "${MESSAGE}"
        [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "critical" "${MESSAGE}"
    fi

    # Check for reallocated sectors
    REALLOCATED=$(smartctl -A ${device} | grep "Reallocated_Sector_Ct" | awk '{print $10}' || echo "0")
    if [[ "${REALLOCATED}" -gt 0 ]]; then
        MESSAGE="WARNING: ${device} has ${REALLOCATED} reallocated sectors"
        echo "${MESSAGE}"
        [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
    fi

    # Check temperature (HDDs)
    if [[ "${device}" != "/dev/nvme"* ]]; then
        TEMP=$(smartctl -A ${device} | grep "Temperature_Celsius" | awk '{print $10}' || echo "0")
        if [[ "${TEMP}" -gt 50 ]]; then
            MESSAGE="WARNING: ${device} temperature is ${TEMP}°C"
            echo "${MESSAGE}"
            [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
        fi
    fi
done
EOF

chmod +x ${SCRIPTS_DIR}/check-disk-smart.sh

# GPU Temperature Monitoring Script
cat > ${SCRIPTS_DIR}/check-gpu-temperature.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"
TEMP_THRESHOLD=80

if ! command -v nvidia-smi &> /dev/null; then
    echo "nvidia-smi not found"
    exit 0
fi

GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)

if [[ "${GPU_TEMP}" -gt "${TEMP_THRESHOLD}" ]]; then
    MESSAGE="WARNING: GPU temperature is ${GPU_TEMP}°C (threshold: ${TEMP_THRESHOLD}°C)"
    echo "${MESSAGE}"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
else
    echo "GPU temperature: ${GPU_TEMP}°C"
fi
EOF

chmod +x ${SCRIPTS_DIR}/check-gpu-temperature.sh

# BTRFS Health Check Script
cat > ${SCRIPTS_DIR}/check-btrfs-health.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"
MOUNT_POINT="/mnt/storage"

if ! mountpoint -q ${MOUNT_POINT}; then
    MESSAGE="CRITICAL: ${MOUNT_POINT} is not mounted!"
    echo "${MESSAGE}"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "critical" "${MESSAGE}"
    exit 1
fi

# Check filesystem usage
USAGE=$(btrfs filesystem usage ${MOUNT_POINT} | grep "Free (estimated)" | awk '{print $3}' | sed 's/[^0-9.]//g')
TOTAL=$(btrfs filesystem usage ${MOUNT_POINT} | grep "Device size" | awk '{print $3}' | sed 's/[^0-9.]//g')

if [[ -n "${USAGE}" ]] && [[ -n "${TOTAL}" ]]; then
    USAGE_PERCENT=$(echo "scale=2; (1 - ${USAGE} / ${TOTAL}) * 100" | bc)
    if (( $(echo "${USAGE_PERCENT} > 90" | bc -l) )); then
        MESSAGE="WARNING: BTRFS filesystem is ${USAGE_PERCENT}% full"
        echo "${MESSAGE}"
        [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
    fi
fi

# Check device stats for errors
if btrfs device stats ${MOUNT_POINT} | grep -v " 0$"; then
    MESSAGE="WARNING: BTRFS device has errors. Run 'btrfs device stats ${MOUNT_POINT}'"
    echo "${MESSAGE}"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
fi
EOF

chmod +x ${SCRIPTS_DIR}/check-btrfs-health.sh

# Container OOM Kill Monitor
cat > ${SCRIPTS_DIR}/check-oom-kills.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"
LOG_FILE="/var/log/oom-kills.log"
LAST_CHECK_FILE="/var/run/oom-last-check"

# Get timestamp of last check
if [[ -f "${LAST_CHECK_FILE}" ]]; then
    LAST_CHECK=$(cat ${LAST_CHECK_FILE})
else
    LAST_CHECK=$(date -d "1 hour ago" +%s)
fi

# Update last check timestamp
date +%s > ${LAST_CHECK_FILE}

# Check for OOM kills since last check
OOM_KILLS=$(journalctl --since="@${LAST_CHECK}" | grep -i "oom" | grep -i "kill" || true)

if [[ -n "${OOM_KILLS}" ]]; then
    echo "${OOM_KILLS}" | tee -a ${LOG_FILE}
    MESSAGE="WARNING: OOM kill detected. Check ${LOG_FILE}"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
fi
EOF

chmod +x ${SCRIPTS_DIR}/check-oom-kills.sh

# Multi-GPU Usage Monitor (detect concurrent usage)
cat > ${SCRIPTS_DIR}/check-gpu-usage.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-slack-alert.sh"

if ! command -v nvidia-smi &> /dev/null; then
    exit 0
fi

# Count processes using GPU
GPU_PROCS=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)

if [[ "${GPU_PROCS}" -gt 1 ]]; then
    PROC_INFO=$(nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader)
    MESSAGE="INFO: Multiple processes using GPU:\n${PROC_INFO}"
    echo -e "${MESSAGE}"
    [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "info" "${MESSAGE}"
fi
EOF

chmod +x ${SCRIPTS_DIR}/check-gpu-usage.sh

# Step 2: Configure Slack webhook
echo ""
echo "=== Step 2: Configuring Slack webhook ==="

read -p "Do you want to configure Slack alerts? (y/n): " setup_slack

if [[ "$setup_slack" == "y" ]]; then
    echo "Create a Slack incoming webhook at: https://api.slack.com/messaging/webhooks"
    echo "Then paste the webhook URL here:"
    read -p "Webhook URL: " slack_webhook
    echo "${slack_webhook}" > /root/.slack-webhook
    chmod 600 /root/.slack-webhook
    echo "Slack webhook configured"

    # Test alert
    ${SCRIPTS_DIR}/send-slack-alert.sh "info" "Monitoring setup complete on ML Training Server"
else
    echo "Skipping Slack configuration"
fi

# Step 3: Enable SMART monitoring
echo ""
echo "=== Step 3: Enabling SMART monitoring ==="

# Configure smartd
cat > /etc/smartd.conf <<EOF
# Monitor all devices
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,35,40 -m root
EOF

systemctl enable smartd
systemctl restart smartd

echo "SMART monitoring enabled"

# Step 4: Setup cron jobs
echo ""
echo "=== Step 4: Setting up monitoring cron jobs ==="

cat > /etc/cron.d/ml-monitoring <<EOF
# Disk SMART checks (daily at 3 AM)
0 3 * * * root ${SCRIPTS_DIR}/check-disk-smart.sh

# BTRFS health check (every 6 hours)
0 */6 * * * root ${SCRIPTS_DIR}/check-btrfs-health.sh

# GPU temperature check (every 15 minutes)
*/15 * * * * root ${SCRIPTS_DIR}/check-gpu-temperature.sh

# OOM kill check (every 30 minutes)
*/30 * * * * root ${SCRIPTS_DIR}/check-oom-kills.sh

# GPU usage check (every hour)
0 * * * * root ${SCRIPTS_DIR}/check-gpu-usage.sh
EOF

echo "Monitoring cron jobs configured"

# Step 5: Configure UPS monitoring (if applicable)
echo ""
read -p "Do you have a UPS connected via USB? (y/n): " has_ups

if [[ "$has_ups" == "y" ]]; then
    echo "Installing NUT (Network UPS Tools)..."
    apt install -y nut

    echo "Configure NUT manually by editing:"
    echo "  /etc/nut/ups.conf"
    echo "  /etc/nut/upsd.conf"
    echo "  /etc/nut/upsmon.conf"
    echo ""
    echo "Refer to: https://networkupstools.org/docs/user-manual.chunked/ar01s06.html"
fi

echo ""
echo "=== Monitoring Setup Complete ==="
echo ""
echo "Monitoring scripts installed:"
echo "  - SMART disk health: ${SCRIPTS_DIR}/check-disk-smart.sh"
echo "  - GPU temperature: ${SCRIPTS_DIR}/check-gpu-temperature.sh"
echo "  - BTRFS health: ${SCRIPTS_DIR}/check-btrfs-health.sh"
echo "  - OOM kills: ${SCRIPTS_DIR}/check-oom-kills.sh"
echo "  - GPU usage: ${SCRIPTS_DIR}/check-gpu-usage.sh"
echo ""
echo "Cron schedule:"
echo "  - SMART: Daily at 3 AM"
echo "  - BTRFS: Every 6 hours"
echo "  - GPU temp: Every 15 minutes"
echo "  - OOM: Every 30 minutes"
echo "  - GPU usage: Every hour"
echo ""
echo "Alerts sent to Slack (if configured)"
echo ""
echo "Next steps:"
echo "  - Check Docker services: cd docker && docker compose ps"
echo "  - Access Grafana: http://localhost:3000"
echo "  - Access Netdata: http://localhost:19999"
echo ""
