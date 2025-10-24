
## Storage Operation

### Adding HDDs to Existing Array

**When:** Need more storage capacity or want to add redundancy.

**Requirements:**
- New HDD(s) physically installed
- BTRFS array must be mounted

**Steps:**

1. **Identify new disk(s)**
   ```bash
   lsblk
   sudo fdisk -l
   # Note new device names (e.g., /dev/sde, /dev/sdf)
   ```

2. **Wipe new disk(s)**
   ```bash
   sudo wipefs -a /dev/sde
   sudo wipefs -a /dev/sdf
   ```

3. **Add to BTRFS array**
   ```bash
   sudo btrfs device add /dev/sde /dev/sdf /mnt/storage
   ```

4. **Rebalance array**
   ```bash
   # For RAID10 (required to apply redundancy to new disks)
   sudo btrfs balance start -dconvert=raid10 -mconvert=raid10 /mnt/storage

   # Check progress
   sudo btrfs balance status /mnt/storage
   ```

5. **Verify new capacity**
   ```bash
   sudo btrfs filesystem df /mnt/storage
   sudo btrfs filesystem show /mnt/storage
   ```

6. **Update configuration documentation**
   ```bash
   nano ~/train-server/config.sh

   # Update HDD_DEVICES for reference
   HDD_DEVICES="/dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf"
   ```

7. **Recalculate VFS cache size** (optional but recommended)
   ```bash
   # Adjust GDRIVE_CACHE_MAX_SIZE based on new capacity
   # Then remount Google Drive shared
   sudo systemctl restart rclone-gdrive-shared
   ```

**Time estimate:** 1-4 hours (depending on data size for rebalance)

**Notes:**
- Rebalance runs in background, system remains operational
- Monitor with `btrfs balance status` periodically
- Rebalance can be paused: `sudo btrfs balance pause /mnt/storage`

---

### Replacing a Failed HDD

**When:** Disk failure detected via SMART monitoring or BTRFS alerts.

**Prerequisites:**
- RAID1 or RAID10 configured (data survives single disk failure)
- Replacement disk available

**Steps:**

1. **Identify failed disk**
   ```bash
   # Check BTRFS device stats
   sudo btrfs device stats /mnt/storage

   # Check kernel messages
   sudo dmesg | grep -i error

   # Check SMART status
   sudo smartctl -a /dev/sdc | grep -i fail
   ```

2. **Remove failed disk from array**
   ```bash
   # If disk still present but failing
   sudo btrfs device delete /dev/sdc /mnt/storage

   # If disk already disconnected
   sudo btrfs device delete missing /mnt/storage
   ```

3. **Physically replace disk**
   - Shutdown server (or hot-swap if supported)
   - Replace failed disk
   - Boot server

4. **Identify new disk**
   ```bash
   lsblk
   # New disk appears (e.g., /dev/sdc)
   ```

5. **Wipe new disk**
   ```bash
   sudo wipefs -a /dev/sdc
   ```

6. **Add new disk to array**
   ```bash
   sudo btrfs device add /dev/sdc /mnt/storage
   ```

7. **Rebalance to restore redundancy**
   ```bash
   sudo btrfs balance start -dconvert=raid10 -mconvert=raid10 /mnt/storage

   # Monitor progress
   watch sudo btrfs balance status /mnt/storage
   ```

8. **Verify health**
   ```bash
   sudo btrfs filesystem show /mnt/storage
   sudo btrfs device stats /mnt/storage
   ```

9. **Send success notification**
   ```bash
   /opt/scripts/monitoring/send-telegram-alert.sh success "Disk /dev/sdc replaced successfully. Array is healthy."
   ```

**Time estimate:** 2-6 hours (including rebalance)

**Critical:** If using RAID0 or single mode, data loss is permanent. Restore from backups.

---

### Expanding NVMe/SSD Cache

**When:** Want larger bcache for better performance.

**Warning:** Complex operation, requires careful planning.

**Steps:**

1. **Check current bcache setup**
   ```bash
   lsblk
   cat /sys/block/bcache*/bcache/cache_mode
   ls -l /sys/fs/bcache/
   ```

2. **Backup critical data** (precaution)

3. **Method A: Add second SSD as additional cache** (if motherboard has slots)
   ```bash
   # Wipe new SSD
   sudo wipefs -a /dev/nvme1n1

   # Create bcache cache device
   sudo make-bcache -C /dev/nvme1n1

   # Attach to existing backing devices (requires matching each one)
   # This is complex - refer to bcache documentation
   ```

4. **Method B: Replace existing SSD with larger one** (downtime required)
   ```bash
   # 1. Detach bcache (switches to direct HDD access)
   sudo bash -c 'echo 1 > /sys/block/bcache0/bcache/detach'

   # 2. Shutdown system
   sudo shutdown -h now

   # 3. Physically replace SSD

   # 4. Boot system

   # 5. Wipe new SSD
   sudo wipefs -a /dev/nvme0n1p2  # Assuming partition 2 is cache

   # 6. Create larger bcache cache
   sudo make-bcache -C /dev/nvme0n1p2

   # 7. Attach backing devices
   CACHE_SET_UUID=$(bcache-super-show /dev/nvme0n1p2 | grep 'cset.uuid' | awk '{print $2}')
   for bcache_dev in /sys/block/bcache*/bcache; do
       echo $CACHE_SET_UUID | sudo tee $bcache_dev/attach
   done

   # 8. Set cache mode
   for bcache_dev in /sys/block/bcache*/bcache; do
       echo writeback | sudo tee $bcache_dev/cache_mode
   done
   ```

5. **Update config.sh** (documentation)
   ```bash
   nano ~/train-server/config.sh
   # Update NVME_DEVICE if changed
   ```

**Time estimate:** 1-3 hours (with downtime)

**Recommendation:** Only perform during scheduled maintenance window.

---

### Converting RAID Levels

**When:** Want to change redundancy level (e.g., RAID10 → RAID1, or vice versa).

**Examples:**
- RAID10 → RAID1 (reduce disk requirements)
- RAID1 → RAID10 (improve performance with more disks)
- RAID0 → RAID10 (add redundancy)

**Steps:**

1. **Check current RAID level**
   ```bash
   sudo btrfs filesystem df /mnt/storage
   ```

2. **Verify sufficient disks for target RAID level**
   - RAID10: Requires 4+ disks
   - RAID1: Requires 2+ disks
   - RAID0: Requires 2+ disks
   - Single: 1+ disk

3. **Convert RAID level**
   ```bash
   # Example: RAID10 to RAID1
   sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/storage

   # Example: RAID1 to RAID10 (needs 4+ disks)
   sudo btrfs balance start -dconvert=raid10 -mconvert=raid10 /mnt/storage

   # Monitor progress
   watch sudo btrfs balance status /mnt/storage
   ```

4. **Verify conversion**
   ```bash
   sudo btrfs filesystem df /mnt/storage
   # Should show new RAID level
   ```

5. **Update configuration**
   ```bash
   nano ~/train-server/config.sh
   BTRFS_RAID_LEVEL="raid1"  # Update to match
   ```

**Time estimate:** 2-8 hours depending on data size

**Storage impact:** RAID level affects usable capacity
- RAID10: ~50% usable (4x20TB → ~40TB)
- RAID1: ~50% usable (2x20TB → ~20TB)
- RAID0: ~100% usable (4x20TB → ~80TB, NO redundancy)

---

### Checking Storage Health

**When:** Regular maintenance (weekly) or investigating performance issues.

**Steps:**

1. **BTRFS filesystem status**
   ```bash
   sudo btrfs filesystem show /mnt/storage
   sudo btrfs filesystem df /mnt/storage
   sudo btrfs filesystem usage /mnt/storage
   ```

2. **Check for errors**
   ```bash
   sudo btrfs device stats /mnt/storage
   # All values should be 0
   ```

3. **Check disk health (SMART)**
   ```bash
   # For each disk
   sudo smartctl -H /dev/sdb
   sudo smartctl -a /dev/sdb | grep -i "reallocated\|pending\|uncorrectable"

   # All disks at once
   for disk in /dev/sd{b..e}; do
       echo "=== $disk ==="
       sudo smartctl -H $disk
   done
   ```

4. **Check bcache status**
   ```bash
   cat /sys/block/bcache0/bcache/state
   # Should show: clean

   cat /sys/block/bcache0/bcache/cache_mode
   # Should show: writeback (or your configured mode)

   # Cache hit ratio
   cat /sys/block/bcache0/bcache/stats_total/cache_hit_ratio
   ```

5. **Check quotas**
   ```bash
   sudo btrfs qgroup show /mnt/storage
   ```

6. **View Netdata dashboard**
   - Open: `http://server_ip:19999`
   - Check: Disk, BTRFS, and SMART sections

**Time estimate:** 5 minutes

**Schedule:** Weekly automated via monitoring scripts

---

### Manual BTRFS Scrub

**When:** Monthly maintenance or after suspected corruption.

**What it does:** Verifies data integrity and repairs errors automatically.

**Steps:**

1. **Start scrub**
   ```bash
   sudo btrfs scrub start /mnt/storage
   ```

2. **Check progress**
   ```bash
   sudo btrfs scrub status /mnt/storage
   ```

3. **Wait for completion** (can take hours for large arrays)
   ```bash
   watch -n 60 sudo btrfs scrub status /mnt/storage
   ```

4. **Review results**
   ```bash
   sudo btrfs scrub status -d /mnt/storage
   # Check for corrected_errors, uncorrectable_errors
   ```

5. **If errors found**
   ```bash
   # Check which device has errors
   sudo btrfs device stats /mnt/storage

   # Consider replacing disk if errors persist
   ```

**Time estimate:** 2-12 hours (runs in background, system operational)

**Recommendation:** Schedule monthly via cron during low-usage hours

---

### Recovering from Disk Full

**When:** BTRFS reaches >95% capacity (performance degrades).

**Steps:**

1. **Identify space usage**
   ```bash
   sudo btrfs filesystem df /mnt/storage
   sudo btrfs filesystem usage /mnt/storage

   # Per-user breakdown
   sudo du -sh /mnt/storage/homes/*
   sudo du -sh /mnt/storage/workspaces/*
   ```

2. **Check snapshots**
   ```bash
   sudo btrfs subvolume list /mnt/storage | grep snapshot

   # Delete old snapshots if needed
   sudo btrfs subvolume delete /mnt/storage/snapshots/homes/alice/2024-01-15_02-00
   ```

3. **Clear VFS cache** (safe, regenerates automatically)
   ```bash
   sudo rm -rf /mnt/storage/cache/gdrive/vfs/*
   ```

4. **Identify large files per user**
   ```bash
   docker exec workspace-alice du -sh /workspace/* | sort -h
   docker exec workspace-alice du -sh /home/alice/* | sort -h
   ```

5. **Contact users to clean up**
   - Send quota usage report
   - Request deletion of unnecessary data

6. **Emergency cleanup options**
   ```bash
   # Clear Docker build cache
   docker system prune -a --volumes -f

   # Clear apt cache
   docker exec workspace-alice apt-get clean
   ```

7. **Balance filesystem** (reclaim space)
   ```bash
   sudo btrfs balance start -dusage=50 /mnt/storage
   ```

**Prevention:** Set up quota monitoring alerts at 80% threshold

**Time estimate:** 1-4 hours depending on user cooperation

---