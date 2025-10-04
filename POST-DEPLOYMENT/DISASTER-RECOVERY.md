

## Disaster Recovery

### OS Disk Failure

**When:** NVMe/SSD containing OS fails.

**Impact:** Storage array survives (BTRFS on HDDs), user data intact.

**Steps:**

1. **Replace failed OS disk**

2. **Install Ubuntu 24.04 LTS**
   - Follow SETUP-GUIDE.md OS installation steps
   - Stop at storage setup (DO NOT format HDDs!)

3. **Clone repository**
   ```bash
   git clone <repo-url> train-server
   cd train-server
   ```

4. **Copy config.sh** (from backup or recreate)
   ```bash
   # From backup
   restic -r gdrive:backups/ml-train-server restore latest \
     --target /tmp/restore --path /config.sh
   cp /tmp/restore/config.sh ~/train-server/

   # Or recreate manually
   cp config.sh.example config.sh
   nano config.sh
   ```

5. **Mount existing BTRFS array**
   ```bash
   sudo mkdir -p /mnt/storage
   sudo mount /dev/sdb /mnt/storage
   # BTRFS auto-detects all disks in array
   ```

6. **Add to /etc/fstab**
   ```bash
   STORAGE_UUID=$(sudo blkid /dev/sdb -s UUID -o value)
   echo "UUID=${STORAGE_UUID} /mnt/storage btrfs defaults,noatime,compress=zstd:3 0 0" | sudo tee -a /etc/fstab
   ```

7. **Re-run setup scripts** (skip storage setup)
   ```bash
   # Skip: 01-setup-storage.sh (already mounted)
   sudo ./scripts/02-setup-gdrive-shared.sh
   sudo ./scripts/04-setup-users.sh
   sudo ./scripts/05-setup-docker.sh
   sudo ./scripts/06-setup-cloudflare-tunnel.sh
   sudo ./scripts/07-setup-firewall.sh
   sudo ./scripts/08-setup-monitoring.sh
   sudo ./scripts/09-setup-backups.sh
   sudo ./scripts/10-setup-data-pipeline.sh
   ```

8. **Build and start containers**
   ```bash
   cd docker
   ./generate-compose.sh
   docker compose build
   docker compose up -d
   ```

9. **Verify everything works**
   ```bash
   docker ps
   nvidia-smi
   df -h
   ./scripts/11-run-tests.sh
   ```

**Time estimate:** 2-4 hours

**Data loss:** None (if BTRFS array intact)

---

### Complete Data Loss Recovery

**When:** Catastrophic failure, all disks lost, or major corruption.

**Prerequisites:** Valid Restic backups in GDrive.

**Steps:**

1. **Install new hardware and OS**
   - Follow SETUP-GUIDE.md from scratch

2. **Run all setup scripts**
   ```bash
   sudo ./scripts/01-setup-storage.sh  # Creates new BTRFS array
   # ... continue with all scripts
   ```

3. **Initialize Restic repository connection**
   ```bash
   restic -r gdrive:backups/ml-train-server snapshots
   # Should list available backups
   ```

4. **Restore all user homes**
   ```bash
   cd /mnt/storage
   restic -r gdrive:backups/ml-train-server restore latest \
     --target /mnt/storage \
     --path /mnt/storage/homes
   ```

5. **Fix permissions**
   ```bash
   for user in alice bob charlie dave eve; do
       sudo chown -R ${user}:${user} /mnt/storage/homes/${user}
   done
   ```

6. **Build and start containers**
   ```bash
   cd ~/train-server/docker
   docker compose build
   docker compose up -d
   ```

7. **Notify users**
   - Workspaces are empty (not backed up by design)
   - Users need to re-download datasets
   - Home directories restored

**Time estimate:** 4-8 hours + restore time

**Data loss:** Workspaces (expected), recent changes since last backup

---

### bcache SSD Failure

**When:** bcache cache device (SSD) fails.

**Impact:** Performance degradation, no data loss.

**Steps:**

1. **Detach failed bcache**
   ```bash
   sudo bash -c 'echo 1 > /sys/block/bcache0/bcache/detach'
   # Repeat for all bcache devices
   ```

2. **System now runs on HDDs only** (slower but operational)

3. **Physically replace SSD**

4. **Wipe new SSD**
   ```bash
   sudo wipefs -a /dev/nvme0n1p2  # Or appropriate partition
   ```

5. **Recreate bcache cache**
   ```bash
   sudo make-bcache -C /dev/nvme0n1p2
   ```

6. **Reattach backing devices**
   ```bash
   CACHE_SET_UUID=$(bcache-super-show /dev/nvme0n1p2 | grep 'cset.uuid' | awk '{print $2}')

   for bcache_dev in /sys/block/bcache*/bcache; do
       echo $CACHE_SET_UUID | sudo tee $bcache_dev/attach
   done
   ```

7. **Set cache mode**
   ```bash
   for bcache_dev in /sys/block/bcache*/bcache; do
       echo writeback | sudo tee $bcache_dev/cache_mode
   done
   ```

8. **Verify**
   ```bash
   cat /sys/block/bcache0/bcache/state
   # Should show: clean
   ```

**Time estimate:** 1 hour

---

### Power Outage Recovery

**When:** Unexpected power loss (UPS exhausted or unavailable).

**Steps:**

1. **Power on server**

2. **Check filesystem**
   ```bash
   sudo dmesg | grep -i error
   sudo btrfs device stats /mnt/storage
   ```

3. **If filesystem is dirty, run scrub**
   ```bash
   sudo btrfs scrub start /mnt/storage
   ```

4. **Check bcache state**
   ```bash
   cat /sys/block/bcache0/bcache/state
   # If dirty:
   sudo bash -c 'echo 1 > /sys/block/bcache0/bcache/writeback_running'
   ```

5. **Verify Docker containers**
   ```bash
   cd ~/train-server/docker
   docker compose ps
   # Restart any stopped containers
   docker compose up -d
   ```

6. **Check for corrupted data**
   ```bash
   sudo btrfs scrub status /mnt/storage
   # Look for errors
   ```

7. **Notify users to check their data**

**Prevention:** Install UPS with monitoring
```bash
sudo apt install -y apcupsd
sudo nano /etc/apcupsd/apcupsd.conf
# Configure UPS connection
sudo systemctl restart apcupsd
```

**Time estimate:** 15-30 minutes

---

### BTRFS Corruption Recovery

**When:** BTRFS errors detected, filesystem won't mount, or data corruption.

**Steps:**

1. **Attempt read-only mount**
   ```bash
   sudo umount /mnt/storage
   sudo mount -o ro,degraded /dev/sdb /mnt/storage

   # If successful, backup critical data immediately
   ```

2. **Check filesystem**
   ```bash
   sudo btrfs check --readonly /dev/sdb
   ```

3. **Attempt repair** (WARNING: Can cause more damage if severe corruption)
   ```bash
   # DO NOT use --repair unless absolutely necessary
   sudo btrfs check --repair /dev/sdb
   ```

4. **Recovery mount options**
   ```bash
   # Try mounting with recovery options
   sudo mount -o ro,usebackuproot /dev/sdb /mnt/storage

   # Or:
   sudo mount -o ro,recovery /dev/sdb /mnt/storage
   ```

5. **If mountable, rescue data**
   ```bash
   rsync -av /mnt/storage/homes/ /mnt/external-backup/homes/
   rsync -av /mnt/storage/workspaces/ /mnt/external-backup/workspaces/
   ```

6. **Restore from backups** (if repair fails)
   - Follow "Complete Data Loss Recovery" steps above

7. **Last resort: btrfs-restore**
   ```bash
   sudo btrfs restore /dev/sdb /mnt/recovery-output/
   ```

**Prevention:**
- Regular scrubs (monthly)
- RAID redundancy (RAID1/RAID10)
- UPS to prevent sudden power loss
- Good backups (tested regularly)

**Time estimate:** 2-8 hours

---