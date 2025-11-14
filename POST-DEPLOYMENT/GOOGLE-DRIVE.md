


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

### Circuit Breaker and Service Recovery

**When:** The Google Drive mount service stops restarting after repeated failures.

**Background:** The systemd service includes a circuit breaker to prevent infinite restart loops. After 5 failures within 10 minutes, the service will stop attempting to restart automatically. This prevents resource waste and log spam when there are permanent issues (invalid credentials, API quota exceeded, network partition, etc.).

**Symptoms:**
- Service shows as "failed" status: `systemctl status gdrive-shared.service`
- Mount point `/shared` is not accessible
- Logs show: "Start request repeated too quickly" or "Failed with result 'start-limit-hit'"

**Recovery Steps:**

1. **Check service status**
   ```bash
   systemctl status gdrive-shared.service
   ```

2. **Identify the root cause** (check logs)
   ```bash
   journalctl -u gdrive-shared.service -n 100
   ```

   Common issues:
   - OAuth token expired/revoked → Reconfigure rclone authentication
   - Google API quota exceeded → Wait for quota reset (usually 24h)
   - Network connectivity issues → Verify internet access
   - Shared Drive deleted/permissions removed → Check Google Drive access
   - Account locked/suspended → Contact Google Workspace admin

3. **Fix the underlying issue** before restarting
   ```bash
   # Example: Refresh OAuth token
   rclone config reconnect gdrive-shared:

   # Example: Test connectivity
   rclone lsd gdrive-shared: --max-depth 1
   ```

4. **Reset the circuit breaker and restart service**
   ```bash
   sudo systemctl reset-failed gdrive-shared.service
   sudo systemctl start gdrive-shared.service
   ```

5. **Verify mount is working**
   ```bash
   mountpoint /mnt/storage/shared
   ls -la /mnt/storage/shared
   ```

6. **Monitor for stability**
   ```bash
   # Watch service status
   watch -n 5 systemctl status gdrive-shared.service

   # Watch logs in real-time
   journalctl -u gdrive-shared.service -f
   ```

**Alert Integration:** When the circuit breaker trips, the system will:
- Send a Telegram alert (if `/opt/scripts/monitoring/send-telegram-alert.sh` exists)
- Log to syslog with tag `gdrive-alert` (always)

**Prevention:**
- Set up monitoring alerts for `systemctl list-units --state=failed`
- Regularly check OAuth token validity
- Monitor Google Drive quota usage
- Set up network connectivity monitoring

**Time estimate:** 5-15 minutes (depends on root cause)

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