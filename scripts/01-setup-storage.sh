#!/bin/bash
set -euo pipefail

# ML Training Server - Storage Setup Script
# Sets up BTRFS RAID on HDDs with bcache on SSD/NVMe
# WARNING: This will DESTROY all data on the specified disks!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

# Load configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "Please create config.sh from config.sh.example and edit it."
    exit 1
fi

source "${CONFIG_FILE}"


echo "=== ML Training Server Storage Setup ==="
echo ""
echo "This script will:"
echo "  1. Detect or use configured storage devices"
echo "  2. Partition SSD/NVMe (${OS_PARTITION_SIZE_GB}GB OS, rest for bcache)"
echo "  3. Create BTRFS ${BTRFS_RAID_LEVEL} on HDDs"
if [[ "${BCACHE_MODE}" != "none" ]]; then
    echo "  4. Configure bcache in ${BCACHE_MODE} mode"
fi
echo "  5. Create directory structure"
echo "  6. Configure /etc/fstab"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Detect devices if not configured
DETECTED_NVME=$(detect_nvme_device)
DETECTED_HDDS=$(detect_hdd_devices)

if [[ -z "${NVME_DEVICE}" ]]; then
    NVME_DEVICE="${DETECTED_NVME}"
fi

if [[ -z "${HDD_DEVICES}" ]]; then
    HDD_DEVICES="${DETECTED_HDDS}"
fi

# Convert HDD_DEVICES to array
HDD_ARRAY=(${HDD_DEVICES})

# Check if we have a single NVMe setup (no HDDs)
SINGLE_NVME_MODE=false
if [[ -n "${NVME_DEVICE}" && ${#HDD_ARRAY[@]} -eq 0 ]]; then
    echo "Single NVMe mode detected (no HDDs)"
    SINGLE_NVME_MODE=true
    # Force bcache to none for single NVMe mode
    BCACHE_MODE="none"
fi

echo "Detected configuration:"
if [[ -n "${NVME_DEVICE}" ]]; then
    echo "  SSD/NVMe: ${NVME_DEVICE}"
    NVME_SIZE=$(lsblk -ndo SIZE ${NVME_DEVICE} 2>/dev/null || echo "unknown")
    NVME_SIZE_GB=$(lsblk -bndo SIZE ${NVME_DEVICE} 2>/dev/null | awk '{print int($1/1024/1024/1024)}' || echo "0")
    echo "    Size: ${NVME_SIZE} (${NVME_SIZE_GB}GB)"

    # Validate OS_PARTITION_SIZE_GB doesn't exceed NVME size
    if [[ ${NVME_SIZE_GB} -gt 0 ]] && [[ ${OS_PARTITION_SIZE_GB} -ge ${NVME_SIZE_GB} ]]; then
        echo "  ERROR: OS_PARTITION_SIZE_GB (${OS_PARTITION_SIZE_GB}GB) must be less than NVME size (${NVME_SIZE_GB}GB)"
        exit 1
    fi

    # Calculate and warn about bcache partition size
    if [[ "${BCACHE_MODE}" != "none" ]] && [[ ${NVME_SIZE_GB} -gt 0 ]]; then
        BCACHE_SIZE_GB=$((NVME_SIZE_GB - OS_PARTITION_SIZE_GB))
        if [[ ${BCACHE_SIZE_GB} -lt 10 ]]; then
            echo "  WARNING: bcache partition will be only ${BCACHE_SIZE_GB}GB (NVME: ${NVME_SIZE_GB}GB - OS: ${OS_PARTITION_SIZE_GB}GB)"
            echo "  This may be too small for effective caching. Consider reducing OS_PARTITION_SIZE_GB or using larger SSD."
        else
            echo "    bcache partition: ${BCACHE_SIZE_GB}GB available"
        fi
    fi
else
    echo "  SSD/NVMe: None detected (bcache will be disabled)"
fi

if [[ ${#HDD_ARRAY[@]} -gt 0 ]]; then
    echo "  HDDs: ${HDD_DEVICES}"
    echo "  HDD count: ${#HDD_ARRAY[@]}"
    for hdd in "${HDD_ARRAY[@]}"; do
        HDD_SIZE=$(lsblk -ndo SIZE ${hdd} 2>/dev/null || echo "unknown")
        echo "    ${hdd}: ${HDD_SIZE}"
    done
else
    echo "  HDDs: None (single NVMe mode)"
fi
echo "  RAID level: ${BTRFS_RAID_LEVEL}"
echo "  Compression: ${BTRFS_COMPRESSION}"
echo "  bcache mode: ${BCACHE_MODE}"
echo "  OS partition: ${OS_PARTITION_SIZE_GB}GB"
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    NVME_SIZE_GB=$(lsblk -bndo SIZE ${NVME_DEVICE} 2>/dev/null | awk '{print int($1/1024/1024/1024)}' || echo "0")
    STORAGE_SIZE_GB=$((NVME_SIZE_GB - OS_PARTITION_SIZE_GB))
    echo "  Storage partition: ${STORAGE_SIZE_GB}GB (from NVMe after OS partition)"
fi
echo ""

# Validate device count for RAID level
DEVICE_COUNT=${#HDD_ARRAY[@]}
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    DEVICE_COUNT=1  # Single NVMe partition
fi

case "${BTRFS_RAID_LEVEL}" in
    raid10)
        if [[ ${DEVICE_COUNT} -lt 4 ]]; then
            echo "ERROR: RAID10 requires at least 4 disks, found ${DEVICE_COUNT}"
            exit 1
        fi
        ;;
    raid1)
        if [[ ${DEVICE_COUNT} -lt 2 ]]; then
            echo "ERROR: RAID1 requires at least 2 disks, found ${DEVICE_COUNT}"
            exit 1
        fi
        ;;
    raid0)
        if [[ ${DEVICE_COUNT} -lt 2 ]]; then
            echo "ERROR: RAID0 requires at least 2 disks, found ${DEVICE_COUNT}"
            exit 1
        fi
        ;;
    single)
        if [[ ${DEVICE_COUNT} -lt 1 ]]; then
            echo "ERROR: At least 1 disk required"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown RAID level: ${BTRFS_RAID_LEVEL}"
        exit 1
        ;;
esac

# Calculate usable capacity
case "${BTRFS_RAID_LEVEL}" in
    raid10)
        echo "  Usable capacity: ~50% of total (RAID10 mirroring)"
        ;;
    raid1)
        echo "  Usable capacity: ~50% of total (RAID1 mirroring)"
        ;;
    raid0)
        echo "  Usable capacity: ~100% of total (NO REDUNDANCY!)"
        ;;
    single)
        echo "  Usable capacity: ~100% of total (NO REDUNDANCY!)"
        ;;
esac

echo ""
echo "WARNING: This will DESTROY all data on:"
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    echo "  - ${NVME_DEVICE} (NVMe - will create storage partition)"
elif [[ -n "${NVME_DEVICE}" && "${BCACHE_MODE}" != "none" ]]; then
    echo "  - ${NVME_DEVICE} (SSD/NVMe - partition for bcache)"
fi
for hdd in "${HDD_ARRAY[@]}"; do
    echo "  - ${hdd} (HDD)"
done
echo ""
read -p "Type 'YES' to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# Install required packages
echo ""
echo "Installing required packages..."
apt update
apt install -y btrfs-progs parted gdisk smartmontools

if [[ "${BCACHE_MODE}" != "none" ]]; then
    echo "Installing bcache-tools for bcache support..."
    # Check Ubuntu version compatibility
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "0")
    UBUNTU_MAJOR=$(echo "${UBUNTU_VERSION}" | cut -d. -f1)
    if [[ ${UBUNTU_MAJOR} -lt 18 ]]; then
        echo "ERROR: bcache-tools requires Ubuntu 18.04 or newer!"
        echo "Current version: Ubuntu ${UBUNTU_VERSION}"
        echo "Please upgrade Ubuntu or set BCACHE_MODE=none in config.sh"
        exit 1
    fi
    if ! apt install -y bcache-tools; then
        echo "ERROR: Failed to install bcache-tools!"
        echo "bcache mode is set to '${BCACHE_MODE}' but bcache-tools cannot be installed."
        echo "Please check your package repositories or set BCACHE_MODE=none in config.sh"
        exit 1
    fi
    echo "bcache-tools installed successfully"
fi

# Check devices exist
echo "Checking devices exist..."
for dev in "${HDD_ARRAY[@]}"; do
    if [[ ! -b "$dev" ]]; then
        echo "ERROR: Device $dev not found!"
        exit 1
    fi
done

if [[ -n "${NVME_DEVICE}" && "${BCACHE_MODE}" != "none" ]]; then
    if [[ ! -b "${NVME_DEVICE}" ]]; then
        echo "ERROR: Device ${NVME_DEVICE} not found!"
        exit 1
    fi
fi

echo "All devices found."

# Step 1: Setup bcache cache device if enabled
if [[ -n "${NVME_DEVICE}" && "${BCACHE_MODE}" != "none" ]]; then
    echo ""
    echo "=== Step 1: Setting up bcache cache device ==="

    # Check if NVMe is partitioned (OS already installed)
    NUM_PARTITIONS=$(lsblk -nlo NAME ${NVME_DEVICE} | wc -l)

    if [[ $NUM_PARTITIONS -gt 1 ]]; then
        # OS is installed, add bcache partition
        echo "OS detected on ${NVME_DEVICE}, creating bcache partition..."

        # Determine partition naming (nvme0n1p3 vs sda3)
        if [[ ${NVME_DEVICE} == *"nvme"* ]]; then
            BCACHE_PARTITION="${NVME_DEVICE}p3"
        else
            BCACHE_PARTITION="${NVME_DEVICE}3"
        fi

        # Get total size and calculate bcache start
        TOTAL_SIZE_GB=$(lsblk -bndo SIZE ${NVME_DEVICE} | awk '{print int($1/1024/1024/1024)}')
        BCACHE_SIZE_GB=$((TOTAL_SIZE_GB - OS_PARTITION_SIZE_GB))

        # Create bcache partition
        if ! parted -s "${NVME_DEVICE}" mkpart primary ${OS_PARTITION_SIZE_GB}GiB 100%; then
            echo "ERROR: Failed to create partition on ${NVME_DEVICE}"
            parted -s "${NVME_DEVICE}" print  # Show current state for debugging
            exit 1
        fi

        # Wait for partition to appear
        sleep 2
        partprobe ${NVME_DEVICE}
        sleep 2

        BCACHE_CACHE_DEV="${BCACHE_PARTITION}"
    else
        # No OS, use entire device for bcache
        echo "No OS detected, using entire ${NVME_DEVICE} for bcache..."
        BCACHE_CACHE_DEV="${NVME_DEVICE}"
    fi

    # Create bcache cache device
    wipefs -af ${BCACHE_CACHE_DEV}
    make-bcache -C ${BCACHE_CACHE_DEV} --wipe-bcache

    echo "bcache cache device created: ${BCACHE_CACHE_DEV}"

    # Verify bcache-super-show command is available
    if ! command -v bcache-super-show &>/dev/null; then
        echo "ERROR: bcache-super-show command not found!"
        echo "bcache-tools may not be installed correctly."
        exit 1
    fi

    # Wait for cache device to be fully ready
    echo "Waiting for bcache cache device to be ready..."
    for i in {1..60}; do
        if [[ -e "/sys/fs/bcache" ]] && bcache-super-show ${BCACHE_CACHE_DEV} &>/dev/null; then
            echo "Cache device ready after ${i} seconds"
            break
        fi
        if [[ $i -eq 60 ]]; then
            echo "ERROR: Timeout waiting for bcache cache device ${BCACHE_CACHE_DEV}"
            echo "Check 'dmesg | tail -50' and verify bcache-tools installed correctly"
            exit 1
        fi
        sleep 1
    done

    # Get cache set UUID
    CACHE_SET_UUID=$(bcache-super-show ${BCACHE_CACHE_DEV} | grep 'cset.uuid' | awk '{print $2}')

    # Validate CACHE_SET_UUID is not empty
    if [[ -z "${CACHE_SET_UUID}" ]]; then
        echo "ERROR: Failed to get cache set UUID from ${BCACHE_CACHE_DEV}"
        echo "bcache-super-show output:"
        bcache-super-show ${BCACHE_CACHE_DEV} || true
        exit 1
    fi

    echo "Cache set UUID: ${CACHE_SET_UUID}"
else
    echo ""
    echo "=== Step 1: Skipping bcache (disabled) ==="
    BCACHE_MODE="none"
fi

# Step 2: Prepare storage devices (HDDs or NVMe partition)
echo ""
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    echo "=== Step 2: Preparing NVMe storage partition ==="
else
    echo "=== Step 2: Preparing HDDs ==="
fi

HDD_DEVICES_FOR_BTRFS=()

# Handle single NVMe mode
if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    echo "Creating storage partition on ${NVME_DEVICE}..."

    # Check if NVMe is partitioned (OS already installed)
    NUM_PARTITIONS=$(lsblk -nlo NAME ${NVME_DEVICE} | wc -l)

    if [[ $NUM_PARTITIONS -gt 1 ]]; then
        # OS is installed, add storage partition
        echo "OS detected on ${NVME_DEVICE}, creating storage partition..."

        # Determine partition naming (nvme0n1p3 vs sda3)
        if [[ ${NVME_DEVICE} == *"nvme"* ]]; then
            STORAGE_PARTITION="${NVME_DEVICE}p3"
        else
            STORAGE_PARTITION="${NVME_DEVICE}3"
        fi

        # Get total size and calculate storage start
        TOTAL_SIZE_GB=$(lsblk -bndo SIZE ${NVME_DEVICE} | awk '{print int($1/1024/1024/1024)}')

        # Create storage partition
        if ! parted -s "${NVME_DEVICE}" mkpart primary btrfs ${OS_PARTITION_SIZE_GB}GiB 100%; then
            echo "ERROR: Failed to create partition on ${NVME_DEVICE}"
            parted -s "${NVME_DEVICE}" print  # Show current state for debugging
            exit 1
        fi

        # Wait for partition to appear
        sleep 2
        partprobe ${NVME_DEVICE}
        sleep 2

        echo "Created storage partition: ${STORAGE_PARTITION}"
        HDD_DEVICES_FOR_BTRFS+=("${STORAGE_PARTITION}")
    else
        # No OS, use entire device
        echo "No OS detected, using entire ${NVME_DEVICE} for storage..."
        wipefs -af ${NVME_DEVICE}
        HDD_DEVICES_FOR_BTRFS+=("${NVME_DEVICE}")
    fi
fi

# Handle HDD mode
for hdd in "${HDD_ARRAY[@]}"; do
    echo "Preparing ${hdd}..."

    # Unmount if mounted
    umount ${hdd}* 2>/dev/null || true

    # Wipe filesystem signatures
    wipefs -af ${hdd}

    if [[ "${BCACHE_MODE}" != "none" ]]; then
        # Create bcache backing device
        make-bcache -B ${hdd} --wipe-bcache

        # Find the bcache device using sysfs (more reliable than lsblk)
        echo "  Waiting for bcache device to appear..."
        udevadm settle --timeout=30
        sleep 2
        BCACHE_DEV=""
        for i in {1..30}; do
            # Check /sys/block/bcache*/slaves/ for the source device
            for bcache_block in /sys/block/bcache*; do
                if [[ -d "${bcache_block}/slaves" ]]; then
                    HDD_BASENAME=$(basename ${hdd})
                    if [[ -e "${bcache_block}/slaves/${HDD_BASENAME}" ]]; then
                        BCACHE_DEV="/dev/$(basename ${bcache_block})"
                        echo "  Found bcache device: ${BCACHE_DEV} (after ${i} seconds)"
                        break 2
                    fi
                fi
            done
            if [[ $i -eq 30 ]]; then
                echo "  ERROR: Timeout waiting for bcache device for ${hdd}"
                exit 1
            fi
            sleep 1
        done

        if [[ -n "${BCACHE_DEV}" ]]; then
            echo "  Created bcache device: ${BCACHE_DEV}"

            # Attach cache
            BCACHE_SYSFS="/sys/block/$(basename ${BCACHE_DEV})/bcache"
            if [[ -n "${CACHE_SET_UUID}" ]]; then
                # Attempt to attach cache
                if ! echo ${CACHE_SET_UUID} > ${BCACHE_SYSFS}/attach 2>/dev/null; then
                    echo "  WARNING: Failed to attach ${BCACHE_DEV} to cache set ${CACHE_SET_UUID}"
                    echo "  This may happen if already attached. Checking attachment status..."

                    # Check if already attached
                    if [[ -f "${BCACHE_SYSFS}/cache_mode" ]]; then
                        echo "  Device appears to be already attached to cache"
                    else
                        echo "  ERROR: bcache attach failed and device not attached"
                        exit 1
                    fi
                fi
                sleep 1

                # Validate bcache device is properly attached
                if [[ ! -f "${BCACHE_SYSFS}/cache_mode" ]]; then
                    echo "  ERROR: bcache device ${BCACHE_DEV} not properly attached (cache_mode not available)"
                    echo "  Check: ls -la ${BCACHE_SYSFS}/"
                    ls -la ${BCACHE_SYSFS}/ || true
                    exit 1
                fi

                # Set cache mode
                if ! echo ${BCACHE_MODE} > ${BCACHE_SYSFS}/cache_mode; then
                    echo "  ERROR: Failed to set cache mode to ${BCACHE_MODE}"
                    exit 1
                fi

                # Tune bcache settings
                echo 0 > ${BCACHE_SYSFS}/sequential_cutoff || true
                echo 100 > ${BCACHE_SYSFS}/writeback_percent || true

                echo "  Attached to cache set in ${BCACHE_MODE} mode"
            fi

            HDD_DEVICES_FOR_BTRFS+=("${BCACHE_DEV}")
        else
            echo "  ERROR: Could not find bcache device for ${hdd}"
            exit 1
        fi
    else
        # No bcache, use raw device
        HDD_DEVICES_FOR_BTRFS+=("${hdd}")
    fi
done

if [[ "${SINGLE_NVME_MODE}" == "true" ]]; then
    echo "NVMe partition ready for BTRFS: ${HDD_DEVICES_FOR_BTRFS[*]}"
else
    echo "Devices ready for BTRFS: ${HDD_DEVICES_FOR_BTRFS[*]}"
fi

# Step 3: Create BTRFS filesystem
echo ""
echo "=== Step 3: Creating BTRFS ${BTRFS_RAID_LEVEL} ==="

# Build mkfs.btrfs command
MKFS_CMD="mkfs.btrfs -f -L ml-storage"

# Add data and metadata RAID levels
if [[ "${BTRFS_RAID_LEVEL}" != "single" ]]; then
    MKFS_CMD="${MKFS_CMD} -d ${BTRFS_RAID_LEVEL} -m ${BTRFS_RAID_LEVEL}"
else
    MKFS_CMD="${MKFS_CMD} -d single -m single"
fi

# Add devices
MKFS_CMD="${MKFS_CMD} ${HDD_DEVICES_FOR_BTRFS[*]}"

echo "Running: ${MKFS_CMD}"
eval ${MKFS_CMD}

# Mount BTRFS
echo "Mounting BTRFS to ${MOUNT_POINT}..."
mkdir -p ${MOUNT_POINT}

MOUNT_OPTS="compress=${BTRFS_COMPRESSION},space_cache=v2,relatime"
mount -o ${MOUNT_OPTS} ${HDD_DEVICES_FOR_BTRFS[0]} ${MOUNT_POINT}

# Verify BTRFS
echo ""
echo "BTRFS created successfully:"
btrfs filesystem show ${MOUNT_POINT}
btrfs filesystem df ${MOUNT_POINT}

# Step 4: Create directory structure
echo ""
echo "=== Step 4: Creating directory structure ==="

mkdir -p ${MOUNT_POINT}/homes
mkdir -p ${MOUNT_POINT}/workspaces
mkdir -p ${MOUNT_POINT}/shared
mkdir -p ${MOUNT_POINT}/shared/tensorboard
mkdir -p ${MOUNT_POINT}/docker-volumes
mkdir -p ${MOUNT_POINT}/snapshots
mkdir -p ${MOUNT_POINT}/cache
mkdir -p ${MOUNT_POINT}/cache/gdrive

chmod 755 ${MOUNT_POINT}/homes
chmod 755 ${MOUNT_POINT}/workspaces
chmod 755 ${MOUNT_POINT}/shared
chmod 755 ${MOUNT_POINT}/docker-volumes
chmod 700 ${MOUNT_POINT}/snapshots
chmod 755 ${MOUNT_POINT}/cache
chmod 755 ${MOUNT_POINT}/cache/gdrive

echo "Directory structure created:"
ls -la ${MOUNT_POINT}/

# Step 5: Configure /etc/fstab
echo ""
echo "=== Step 5: Configuring /etc/fstab ==="

# Get BTRFS UUID
BTRFS_UUID=$(blkid -s UUID -o value ${HDD_DEVICES_FOR_BTRFS[0]})

# Backup fstab
cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)

# Add BTRFS mount to fstab
if ! grep -q "${BTRFS_UUID}" /etc/fstab; then
    echo "" >> /etc/fstab
    echo "# BTRFS ${BTRFS_RAID_LEVEL} Storage" >> /etc/fstab
    echo "UUID=${BTRFS_UUID} ${MOUNT_POINT} btrfs ${MOUNT_OPTS} 0 0" >> /etc/fstab
    echo "Added BTRFS mount to /etc/fstab"
else
    echo "BTRFS mount already in /etc/fstab"
fi

# Step 6: Enable bcache at boot
if [[ "${BCACHE_MODE}" != "none" ]]; then
    echo ""
    echo "=== Step 6: Configuring bcache persistence ==="

    # Create bcache init script
    cat > /etc/systemd/system/bcache-setup.service <<EOF
[Unit]
Description=Setup bcache ${BCACHE_MODE} mode
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for dev in /sys/block/bcache*/bcache/cache_mode; do echo ${BCACHE_MODE} > \$dev 2>/dev/null || true; done'
ExecStart=/bin/bash -c 'for dev in /sys/block/bcache*/bcache/sequential_cutoff; do echo 0 > \$dev 2>/dev/null || true; done'
ExecStart=/bin/bash -c 'for dev in /sys/block/bcache*/bcache/writeback_percent; do echo 100 > \$dev 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bcache-setup.service
    systemctl start bcache-setup.service

    echo "bcache persistence configured"
fi

# Step 7: Setup weekly BTRFS scrub
echo ""
echo "=== Step 7: Setting up weekly BTRFS scrub ==="

mkdir -p /etc/cron.weekly
cat > /etc/cron.weekly/btrfs-scrub <<EOF
#!/bin/bash
# Weekly BTRFS scrub (runs on Saturday)
btrfs scrub start -B ${MOUNT_POINT}
btrfs scrub status ${MOUNT_POINT} | logger -t btrfs-scrub
EOF

chmod +x /etc/cron.weekly/btrfs-scrub

echo "Weekly BTRFS scrub configured (runs every Saturday)"

# Final verification
echo ""
echo "=== Storage Setup Complete ==="
echo ""
echo "BTRFS Status:"
btrfs filesystem show ${MOUNT_POINT}
echo ""
btrfs filesystem df ${MOUNT_POINT}
echo ""

if [[ "${BCACHE_MODE}" != "none" ]]; then
    echo "bcache Status:"
    for bcache_dev in /dev/bcache*; do
        if [[ -b "${bcache_dev}" ]]; then
            bcache_sysfs="/sys/block/$(basename ${bcache_dev})/bcache"
            if [[ -f "${bcache_sysfs}/cache_mode" ]]; then
                echo "  $(basename ${bcache_dev}): cache_mode=$(cat ${bcache_sysfs}/cache_mode)"
            fi
        fi
    done
    echo ""
fi

echo "Mount point: ${MOUNT_POINT}"
echo "RAID level: ${BTRFS_RAID_LEVEL}"
echo "Compression: ${BTRFS_COMPRESSION}"

# Calculate usable capacity
TOTAL_RAW=$(btrfs filesystem show ${MOUNT_POINT} | grep 'Total devices' | awk '{print $4}')
echo "Total raw capacity: ${TOTAL_RAW}"

case "${BTRFS_RAID_LEVEL}" in
    raid10|raid1)
        echo "Usable capacity: ~50% (mirrored)"
        ;;
    *)
        echo "Usable capacity: ~100% (not mirrored)"
        ;;
esac

echo ""
echo "✅ Storage setup complete!"
echo ""
echo "Next steps:"
echo "  1. REBOOT to verify mounts persist"
echo "  2. Run ./01b-setup-gdrive-shared.sh to mount Google Drive Shared Drive to /shared"
echo "     (Optional: Skip if using local storage for /shared)"
echo "  3. Run ./02-setup-users.sh to create user accounts"
echo ""
echo "Note: The /shared directory is prepared for either:"
echo "  - Local BTRFS storage (current default)"
echo "  - Google Drive Workspace Shared Drive"
echo "  Run ./01b-setup-gdrive-shared.sh to configure Google Drive mount."
echo ""
