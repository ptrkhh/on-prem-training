


## Google Drive Integration

### Reconfiguring Shared Drive Mount

**When:** Changing Shared Drive, updating credentials, or fixing mount issues.

**Steps:**

1. **Stop rclone mount**
   ```bash
   sudo systemctl stop rclone-gdrive-shared
   ```

2. **Reconfigure rclone remote**
   ```bash
   rclone config reconnect gdrive-shared:
   # Or create new remote:
   rclone config
   ```

3. **Update configuration** (if remote name changed)
   ```bash
   nano ~/train-server/config.sh
   GDRIVE_SHARED_REMOTE="gdrive-shared-new"
   ```

4. **Re-run setup script**
   ```bash
   sudo ./scripts/02-setup-gdrive-shared.sh
   ```

5. **Verify mount**
   ```bash
   ls -la /shared
   df -h | grep shared
   ```

6. **Test write access**
   ```bash
   docker exec workspace-alice touch /shared/test-file
   ls -la /shared/test-file
   ```

**Time estimate:** 10 minutes

---

### Adjusting Cache Size

**When:** Storage capacity changed, usage patterns shifted, or performance tuning.

**Steps:**

1. **Check current cache usage**
   ```bash
   du -sh /mnt/storage/cache/gdrive
   ```

2. **Update cache settings**
   ```bash
   nano ~/train-server/config.sh

   # Adjust cache size (calculated automatically based on free space)
   STORAGE_SAFETY_MARGIN_PERCENT=15  # Was: 20 (allows more cache)

   # Or adjust cache max age
   GDRIVE_CACHE_MAX_AGE="1440h"  # Was: 720h (60 days instead of 30)
   ```

3. **Clear existing cache** (optional, to start fresh)
   ```bash
   sudo systemctl stop rclone-gdrive-shared
   sudo rm -rf /mnt/storage/cache/gdrive/vfs/*
   ```

4. **Remount with new settings**
   ```bash
   sudo ./scripts/02-setup-gdrive-shared.sh
   ```

5. **Monitor cache growth**
   ```bash
   watch -n 60 du -sh /mnt/storage/cache/gdrive
   ```

**Time estimate:** 10 minutes

---

### Remounting After Disconnection

**When:** Network outage, authentication expired, or mount became stale.

**Steps:**

1. **Check mount status**
   ```bash
   df -h | grep shared
   ls /shared  # May hang if mount is stale
   ```

2. **Unmount forcefully if needed**
   ```bash
   sudo umount -l /shared
   # Or:
   sudo fusermount -uz /shared
   ```

3. **Restart rclone service**
   ```bash
   sudo systemctl restart rclone-gdrive-shared
   ```

4. **Verify mount**
   ```bash
   df -h | grep shared
   ls -la /shared
   ```

5. **If still failing, check logs**
   ```bash
   sudo journalctl -u rclone-gdrive-shared -n 50
   ```

6. **Common fixes:**
   ```bash
   # Reauthorize rclone
   rclone config reconnect gdrive-shared:

   # Check rclone version (update if old)
   rclone version
   sudo rclone selfupdate

   # Remount manually
   sudo systemctl restart rclone-gdrive-shared
   ```

**Time estimate:** 5-10 minutes

---

### Migrating to Different Shared Drive

**When:** Organization change, moving to different Google Workspace, or consolidation.

**Steps:**

1. **Create new rclone remote for new Shared Drive**
   ```bash
   rclone config
   # Name: gdrive-shared-new
   # Select Google Drive, authenticate, select new Shared Drive
   ```

2. **Test access**
   ```bash
   rclone lsd gdrive-shared-new:
   ```

3. **Stop current mount**
   ```bash
   sudo systemctl stop rclone-gdrive-shared
   ```

4. **Optional: Copy data to new Shared Drive**
   ```bash
   rclone sync gdrive-shared: gdrive-shared-new: --progress
   ```

5. **Update configuration**
   ```bash
   nano ~/train-server/config.sh
   GDRIVE_SHARED_REMOTE="gdrive-shared-new"
   ```

6. **Re-run setup**
   ```bash
   sudo ./scripts/02-setup-gdrive-shared.sh
   ```

7. **Verify mount**
   ```bash
   ls -la /shared
   ```

8. **Update user scripts** (if hardcoded paths exist)

**Time estimate:** 30 minutes + data copy time

---