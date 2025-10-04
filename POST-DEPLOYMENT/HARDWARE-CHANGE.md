
## Hardware Change

### Replacing or Adding GPU

**When:** GPU upgrade, failure, or adding second GPU.

**Steps:**

1. **Shutdown system**
   ```bash
   # Notify users first!
   sudo shutdown -h now
   ```

2. **Physically install/replace GPU**

3. **Boot system**

4. **Verify GPU detection**
   ```bash
   lspci | grep -i nvidia
   nvidia-smi
   ```

5. **Update NVIDIA drivers** (if needed)
   ```bash
   # Check current driver
   nvidia-smi | grep "Driver Version"

   # Update if needed
   sudo apt update
   sudo apt install -y nvidia-driver-555  # Use latest version
   sudo reboot
   ```

6. **Verify GPU in containers**
   ```bash
   docker exec workspace-alice nvidia-smi
   ```

7. **Enable GPU timeslicing** (optional, for sharing single GPU)
   ```bash
   nano ~/train-server/config.sh
   ENABLE_GPU_TIMESLICING=true

   # Re-run Docker setup
   sudo ./scripts/05-setup-docker.sh

   # Restart containers
   cd docker && docker compose restart
   ```

8. **Test GPU access**
   ```bash
   docker exec workspace-alice python3 -c "import torch; print(torch.cuda.device_count())"
   ```

**Time estimate:** 30 minutes + reboot time

---

### Upgrading RAM

**When:** Need more memory for users or adding more users.

**Steps:**

1. **Shutdown system**
   ```bash
   sudo shutdown -h now
   ```

2. **Install new RAM modules**

3. **Boot and verify**
   ```bash
   free -h
   # Should show new total RAM

   # Check all sticks detected
   sudo dmidecode --type memory | grep -i size
   ```

4. **Update configuration** (if adjusting per-user limits)
   ```bash
   nano ~/train-server/config.sh

   # Calculate new limits based on total RAM
   # Example: 256GB total, 5 users
   MEMORY_GUARANTEE_GB=40    # 40GB × 5 = 200GB (leave 56GB for system)
   MEMORY_LIMIT_GB=120
   ```

5. **Regenerate docker-compose.yml**
   ```bash
   cd ~/train-server/docker
   ./generate-compose.sh
   ```

6. **Restart containers with new limits**
   ```bash
   docker compose up -d --force-recreate
   ```

7. **Verify new limits**
   ```bash
   docker stats --no-stream
   ```

**Time estimate:** 20 minutes + downtime

---

### Replacing Motherboard/CPU

**When:** Hardware failure or upgrade.

**Critical:** Storage array survives this change (BTRFS stores metadata on disks).

**Steps:**

1. **Backup everything** (precaution)
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

2. **Document current setup**
   ```bash
   # Save disk UUIDs and mount info
   sudo blkid > ~/disk-uuids-backup.txt
   cat /etc/fstab > ~/fstab-backup.txt
   lsblk > ~/lsblk-backup.txt
   ```

3. **Shutdown system**
   ```bash
   sudo shutdown -h now
   ```

4. **Transfer components to new motherboard**
   - Move RAM
   - Move NVMe SSD (or clone OS partition)
   - Move all HDDs
   - Move GPU

5. **Boot system**

6. **Verify disk detection**
   ```bash
   lsblk
   # All disks should appear (may have different /dev names)
   ```

7. **Mount storage array**
   ```bash
   # BTRFS auto-detects array from any member disk
   sudo mount /dev/sdb /mnt/storage
   # Or use UUID from fstab
   ```

8. **Update /etc/fstab** (if disk device names changed)
   ```bash
   sudo nano /etc/fstab
   # Ensure using UUID, not /dev/sdX paths
   ```

9. **Verify Docker and containers**
   ```bash
   cd ~/train-server/docker
   docker compose up -d
   docker ps
   ```

10. **Test GPU access**
    ```bash
    nvidia-smi
    docker exec workspace-alice nvidia-smi
    ```

**Time estimate:** 2-4 hours

**Risk level:** Medium (storage array should survive, but test backups first)

---

### Moving to New Hardware

**When:** Complete hardware refresh, datacenter move, or migration.

**Steps:**

1. **Prepare new hardware**
   - Install Ubuntu 24.04 LTS
   - Install same number/size of disks (or larger)

2. **Backup all data from old server**
   ```bash
   # On old server
   sudo /opt/scripts/backup/run-restic-backup.sh

   # Or rsync to external drive
   sudo rsync -avP /mnt/storage/ /mnt/external-backup/
   ```

3. **Clone git repository to new server**
   ```bash
   # On new server
   git clone <repo-url> train-server
   cd train-server
   ```

4. **Copy config.sh from old server**
   ```bash
   scp old-server:~/train-server/config.sh ~/train-server/
   ```

5. **Run setup scripts on new server**
   ```bash
   # Follow SETUP-GUIDE.md from scratch
   sudo ./scripts/01-setup-storage.sh
   # ... continue with all setup scripts
   ```

6. **Restore user data**
   ```bash
   # Option A: From Restic backup
   cd /mnt/storage/homes
   restic restore latest --target . --path /homes

   # Option B: From rsync backup
   sudo rsync -avP /mnt/external-backup/homes/ /mnt/storage/homes/
   sudo rsync -avP /mnt/external-backup/workspaces/ /mnt/storage/workspaces/
   ```

7. **Build and start containers**
   ```bash
   cd docker
   docker compose build
   docker compose up -d
   ```

8. **Update DNS/Cloudflare Tunnel**
   - Point domain to new server IP
   - Reconfigure Cloudflare Tunnel

9. **Verify everything works**
   ```bash
   ./scripts/11-run-tests.sh
   ```

10. **Decommission old server**

**Time estimate:** 4-8 hours

---