#!/bin/bash
set -euo pipefail

# ML Training Server - Monitoring and Alerting Setup

echo "=== Monitoring and Alerting Setup ==="

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

SCRIPTS_DIR="/opt/scripts/monitoring"

# Install required packages
echo "Installing required packages..."
apt update
apt install -y smartmontools bc jq curl mailutils

# Step 1: Create monitoring scripts directory
echo ""
echo "=== Step 1: Creating monitoring scripts ==="

mkdir -p ${SCRIPTS_DIR}

# Telegram Alert Script
cat > ${SCRIPTS_DIR}/send-telegram-alert.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Send alert to Telegram
# Usage: send-telegram-alert.sh <level> <message>
# Level: info, warning, critical, success

LEVEL="$1"
MESSAGE="$2"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Load from config files if not in environment
if [[ -z "${TELEGRAM_BOT_TOKEN}" ]] && [[ -f /root/.telegram-bot-token ]]; then
    TELEGRAM_BOT_TOKEN=$(cat /root/.telegram-bot-token)
fi

if [[ -z "${TELEGRAM_CHAT_ID}" ]] && [[ -f /root/.telegram-chat-id ]]; then
    TELEGRAM_CHAT_ID=$(cat /root/.telegram-chat-id)
fi

if [[ -z "${TELEGRAM_BOT_TOKEN}" ]] || [[ -z "${TELEGRAM_CHAT_ID}" ]]; then
    echo "No Telegram configuration found"
    echo "${LEVEL}: ${MESSAGE}"
    exit 0
fi

# Set emoji based on level
case "${LEVEL}" in
    info)
        EMOJI="ℹ️"
        ;;
    warning)
        EMOJI="⚠️"
        ;;
    critical)
        EMOJI="🔥"
        ;;
    success)
        EMOJI="✅"
        ;;
    *)
        EMOJI="📢"
        ;;
esac

HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Escape special Markdown characters in message
MESSAGE=$(echo "${MESSAGE}" | sed 's/[_*`\[]/\\&/g')

# Format message (Telegram supports Markdown)
TEXT="${EMOJI} *ML Training Server Alert*

*Level:* ${LEVEL^^}
*Server:* \`${HOSTNAME}\`
*Time:* ${TIMESTAMP}

${MESSAGE}"

# Send to Telegram using Bot API
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d @- > /dev/null <<PAYLOAD
{
    "chat_id": "${TELEGRAM_CHAT_ID}",
    "text": $(echo "${TEXT}" | jq -Rs .),
    "parse_mode": "Markdown",
    "disable_web_page_preview": true
}
PAYLOAD

echo "Alert sent to Telegram: ${LEVEL}"
EOF

chmod +x ${SCRIPTS_DIR}/send-telegram-alert.sh

# SMART Monitoring Script
cat > ${SCRIPTS_DIR}/check-disk-smart.sh <<EOF
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

# Auto-detect devices from configuration
DETECTED_DEVICES=""
[[ -n "${NVME_DEVICE}" ]] && [[ -b "${NVME_DEVICE}" ]] && DETECTED_DEVICES="${NVME_DEVICE}"
for dev in ${HDD_DEVICES}; do
    [[ -b "\${dev}" ]] && DETECTED_DEVICES="\${DETECTED_DEVICES} \${dev}"
done
DEVICES=(\${DETECTED_DEVICES})

for device in "\${DEVICES[@]}"; do
    if [[ ! -b "\${device}" ]]; then
        continue
    fi

    # Run SMART test
    if smartctl -H \${device} | grep -q "PASSED"; then
        echo "\${device}: SMART status PASSED"
    else
        MESSAGE="CRITICAL: SMART test failed for \${device}!"
        echo "\${MESSAGE}"
        [[ -x "\${ALERT_SCRIPT}" ]] && \${ALERT_SCRIPT} "critical" "\${MESSAGE}"
    fi

    # Check for reallocated sectors
    REALLOCATED=\$(smartctl -A \${device} | grep "Reallocated_Sector_Ct" | awk '{print \$10}' || echo "0")
    if [[ "\${REALLOCATED}" -gt 0 ]]; then
        MESSAGE="WARNING: \${device} has \${REALLOCATED} reallocated sectors"
        echo "\${MESSAGE}"
        [[ -x "\${ALERT_SCRIPT}" ]] && \${ALERT_SCRIPT} "warning" "\${MESSAGE}"
    fi

done
EOF

chmod +x ${SCRIPTS_DIR}/check-disk-smart.sh

# GPU Temperature Monitoring Script
cat > ${SCRIPTS_DIR}/check-gpu-temperature.sh <<'EOF'
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
TEMP_THRESHOLD=85

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

# Update the threshold value in the generated script
if ! sed -i "s/TEMP_THRESHOLD=85/TEMP_THRESHOLD=${GPU_TEMP_THRESHOLD}/" ${SCRIPTS_DIR}/check-gpu-temperature.sh; then
    echo "ERROR: Failed to update GPU temperature threshold with sed"
    exit 1
fi

# Verify the change took effect
if ! grep -q "TEMP_THRESHOLD=${GPU_TEMP_THRESHOLD}" ${SCRIPTS_DIR}/check-gpu-temperature.sh; then
    echo "ERROR: Temperature threshold not properly updated in ${SCRIPTS_DIR}/check-gpu-temperature.sh"
    echo "Expected: TEMP_THRESHOLD=${GPU_TEMP_THRESHOLD}"
    exit 1
fi

echo "✓ GPU temperature threshold set to ${GPU_TEMP_THRESHOLD}°C"

chmod +x ${SCRIPTS_DIR}/check-gpu-temperature.sh

# BTRFS Health Check Script
cat > ${SCRIPTS_DIR}/check-btrfs-health.sh <<EOF
#!/bin/bash
set -euo pipefail

ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
MOUNT_POINT="${MOUNT_POINT}"

if ! mountpoint -q ${MOUNT_POINT}; then
    MESSAGE="CRITICAL: ${MOUNT_POINT} is not mounted!"
    echo "${MESSAGE}"
    [[ -x "\${ALERT_SCRIPT}" ]] && \${ALERT_SCRIPT} "critical" "\${MESSAGE}"
    exit 1
fi

# Check filesystem usage (using df with --output for reliable parsing)
USAGE_PERCENT=\$(df --output=pcent "\${MOUNT_POINT}" | tail -1 | tr -d ' %')

if [[ -n "\${USAGE_PERCENT}" ]]; then
    if (( \${USAGE_PERCENT} > 90 )); then
        MESSAGE="WARNING: BTRFS filesystem is ${USAGE_PERCENT}% full"
        echo "${MESSAGE}"
        [[ -x "${ALERT_SCRIPT}" ]] && ${ALERT_SCRIPT} "warning" "${MESSAGE}"
    fi
fi

# Check device stats for errors
if btrfs device stats ${MOUNT_POINT} | grep -v " 0\$"; then
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

ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"
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

ALERT_SCRIPT="/opt/scripts/monitoring/send-telegram-alert.sh"

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

# GPU Metrics Export Script (for Prometheus node-exporter)
cat > ${SCRIPTS_DIR}/export-gpu-metrics.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Export GPU metrics to Prometheus node-exporter textfile collector
sanitize_metric_value() {
    local value="${1:-}"
    if [[ -z "${value}" || "${value}" == "N/A" || "${value}" == "[Not Supported]" ]]; then
        echo "0"
    else
        echo "${value}"
    fi
}

sanitize_int_value() {
    local value
    value="$(sanitize_metric_value "$1")"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        echo "${value}"
    else
        echo "0"
    fi
}

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${TEXTFILE_DIR}/gpu_metrics.prom"
TEMP_FILE="${PROM_FILE}.$$"

# Create directory if it doesn't exist
mkdir -p "${TEXTFILE_DIR}"

if ! command -v nvidia-smi &> /dev/null; then
    # No GPU, export empty metrics
    echo "# No NVIDIA GPU detected" > "${TEMP_FILE}"
    mv "${TEMP_FILE}" "${PROM_FILE}"
    exit 0
fi

# Get GPU count
GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)

# Start metrics file
cat > "${TEMP_FILE}" << 'PROM'
# HELP nvidia_gpu_temperature_celsius GPU temperature in Celsius
# TYPE nvidia_gpu_temperature_celsius gauge
# HELP nvidia_gpu_utilization_percent GPU utilization percentage
# TYPE nvidia_gpu_utilization_percent gauge
# HELP nvidia_gpu_memory_used_bytes GPU memory used in bytes
# TYPE nvidia_gpu_memory_used_bytes gauge
# HELP nvidia_gpu_memory_total_bytes GPU memory total in bytes
# TYPE nvidia_gpu_memory_total_bytes gauge
# HELP nvidia_gpu_power_draw_watts GPU power draw in watts
# TYPE nvidia_gpu_power_draw_watts gauge
# HELP nvidia_gpu_fan_speed_percent GPU fan speed percentage
# TYPE nvidia_gpu_fan_speed_percent gauge
PROM

# Query all GPUs at once
nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,fan.speed,name \
    --format=csv,noheader,nounits | \
while IFS=', ' read -r idx temp util mem_used mem_total power fan name; do
    temp_value=$(sanitize_metric_value "${temp}")
    util_value=$(sanitize_metric_value "${util}")
    mem_used_value=$(sanitize_int_value "${mem_used}")
    mem_total_value=$(sanitize_int_value "${mem_total}")
    power_value=$(sanitize_metric_value "${power}")
    fan_value=$(sanitize_metric_value "${fan}")

    # Convert MiB to bytes
    mem_used_bytes=$((${mem_used_value} * 1024 * 1024))
    mem_total_bytes=$((${mem_total_value} * 1024 * 1024))

    cat >> "${TEMP_FILE}" << METRICS
nvidia_gpu_temperature_celsius{gpu="${idx}",name="${name}"} ${temp_value}
nvidia_gpu_utilization_percent{gpu="${idx}",name="${name}"} ${util_value}
nvidia_gpu_memory_used_bytes{gpu="${idx}",name="${name}"} ${mem_used_bytes}
nvidia_gpu_memory_total_bytes{gpu="${idx}",name="${name}"} ${mem_total_bytes}
nvidia_gpu_power_draw_watts{gpu="${idx}",name="${name}"} ${power_value}
nvidia_gpu_fan_speed_percent{gpu="${idx}",name="${name}"} ${fan_value}
METRICS
done

# Atomically replace the metrics file
mv "${TEMP_FILE}" "${PROM_FILE}"
EOF

chmod +x ${SCRIPTS_DIR}/export-gpu-metrics.sh

# Step 2: Configure Telegram Bot
echo ""
echo "=== Step 2: Configuring Telegram Bot ==="

# Check if already configured in config.sh
if [[ -n "${TELEGRAM_BOT_TOKEN}" ]] && [[ -n "${TELEGRAM_CHAT_ID}" ]]; then
    echo "Telegram credentials found in config.sh"
    telegram_bot_token="${TELEGRAM_BOT_TOKEN}"
    telegram_chat_id="${TELEGRAM_CHAT_ID}"

    echo "${telegram_bot_token}" > /root/.telegram-bot-token
    echo "${telegram_chat_id}" > /root/.telegram-chat-id
    chmod 600 /root/.telegram-bot-token
    chmod 600 /root/.telegram-chat-id

    echo "Telegram bot configured from config.sh"

    # Test alert
    export TELEGRAM_BOT_TOKEN="${telegram_bot_token}"
    export TELEGRAM_CHAT_ID="${telegram_chat_id}"
    ${SCRIPTS_DIR}/send-telegram-alert.sh "success" "Monitoring setup complete on ML Training Server"
else
    while true; do
        read -p "Do you want to configure Telegram alerts? (y/n): " setup_telegram
        if [[ "${setup_telegram}" =~ ^[yn]$ ]]; then
            break
        fi
        echo "ERROR: Invalid input. Please enter 'y' or 'n'"
    done

    if [[ "$setup_telegram" == "y" ]]; then
        echo ""
        echo "To setup Telegram notifications:"
        echo "1. Open Telegram and search for @BotFather"
        echo "2. Send /newbot and follow the instructions"
        echo "3. Copy the bot token (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
        echo "4. Search for @userinfobot or @RawDataBot to get your Chat ID"
        echo "5. Start a chat with your bot (search for it by name)"
        echo ""
        read -p "Bot Token: " telegram_bot_token
        # Validate bot token format (should be numbers:alphanumeric)
        if [[ ! "${telegram_bot_token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            echo "ERROR: Invalid Telegram bot token format"
            echo "Expected format: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
            exit 1
        fi

        read -p "Chat ID: " telegram_chat_id
        # Validate chat ID is numeric (can be negative for group chats)
        if [[ ! "${telegram_chat_id}" =~ ^-?[0-9]+$ ]]; then
            echo "ERROR: Invalid Chat ID. Must be numeric (e.g., 123456789 or -123456789)"
            exit 1
        fi

        echo "${telegram_bot_token}" > /root/.telegram-bot-token
        echo "${telegram_chat_id}" > /root/.telegram-chat-id
        chmod 600 /root/.telegram-bot-token
        chmod 600 /root/.telegram-chat-id

        echo "Telegram bot configured"

        # Test alert
        export TELEGRAM_BOT_TOKEN="${telegram_bot_token}"
        export TELEGRAM_CHAT_ID="${telegram_chat_id}"
        ${SCRIPTS_DIR}/send-telegram-alert.sh "success" "Monitoring setup complete on ML Training Server"
    else
        echo "Skipping Telegram configuration"
    fi
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

# GPU metrics export for Prometheus (every minute)
* * * * * root ${SCRIPTS_DIR}/export-gpu-metrics.sh
EOF

echo "Monitoring cron jobs configured"

# Step 5: Configure UPS monitoring (if applicable)
echo ""
read -p "Do you have a UPS connected via USB? (y/n): " has_ups
# Validate y/n input
if [[ ! "${has_ups}" =~ ^[yn]$ ]]; then
    echo "ERROR: Invalid input. Please enter 'y' or 'n'"
    exit 1
fi

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
echo "Alerts sent to Telegram (if configured)"
echo ""
echo "Next steps:"
echo "  - Check Docker services: cd docker && docker compose ps"
echo "  - Access Grafana: http://localhost:3000"
echo "  - Access Netdata: http://localhost:19999"
echo ""
