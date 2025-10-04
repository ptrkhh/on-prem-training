

## Backup and Restore

### Manual Backup Trigger

**When:** Before risky operations, on-demand backup, or testing backup system.

**Steps:**

1. **Run backup script**
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

2. **Monitor progress**
   ```bash
   tail -f /var/log/restic-backup.log
   ```

3. **Verify backup completion**
   ```bash
   restic -r gdrive:backups/ml-train-server snapshots
   ```

4. **Check backup size**
   ```bash
   restic -r gdrive:backups/ml-train-server stats latest
   ```

**Time estimate:** 1-6 hours depending on data size and bandwidth

---

### Restoring User Home Directory

**When:** User accidentally deleted files, corruption, or migration.

**Steps:**

1. **List available backups**
   ```bash
   restic -r gdrive:backups/ml-train-server snapshots
   # Note snapshot ID
   ```

2. **Browse backup contents**
   ```bash
   restic -r gdrive:backups/ml-train-server ls <snapshot-id> | grep alice
   ```

3. **Restore to temporary location**
   ```bash
   mkdir -p /tmp/restore-alice
   restic -r gdrive:backups/ml-train-server restore <snapshot-id> \
     --target /tmp/restore-alice \
     --path /mnt/storage/homes/alice
   ```

4. **Verify restored data**
   ```bash
   ls -la /tmp/restore-alice/mnt/storage/homes/alice/
   ```

5. **Copy to user's home** (container must be stopped)
   ```bash
   docker compose stop workspace-alice
   sudo rsync -av /tmp/restore-alice/mnt/storage/homes/alice/ /mnt/storage/homes/alice/
   docker compose start workspace-alice
   ```

6. **Fix permissions**
   ```bash
   docker exec workspace-alice chown -R alice:alice /home/alice
   ```

7. **Notify user**

**Time estimate:** 30 minutes - 2 hours

---

### Restoring from BTRFS Snapshot

**When:** Recent data loss (within snapshot retention window).

**Advantages:** Much faster than Restic, local restore.

**Steps:**

1. **List snapshots**
   ```bash
   sudo btrfs subvolume list /mnt/storage | grep alice
   # Find most recent snapshot before data loss
   ```

2. **Browse snapshot**
   ```bash
   ls -la /mnt/storage/snapshots/homes/alice/2025-01-24_14-00/
   ```

3. **Restore specific files**
   ```bash
   sudo cp -av /mnt/storage/snapshots/homes/alice/2025-01-24_14-00/important-file.txt \
     /mnt/storage/homes/alice/
   ```

4. **Restore entire directory**
   ```bash
   docker compose stop workspace-alice
   sudo rm -rf /mnt/storage/homes/alice/*
   sudo cp -av /mnt/storage/snapshots/homes/alice/2025-01-24_14-00/* \
     /mnt/storage/homes/alice/
   docker compose start workspace-alice
   ```

5. **Fix permissions**
   ```bash
   docker exec workspace-alice chown -R alice:alice /home/alice
   ```

**Time estimate:** 5-30 minutes

---

### Testing Backup Integrity

**When:** Monthly verification, after backup system changes, or before disaster recovery.

**Steps:**

1. **Check Restic repository integrity**
   ```bash
   restic -r gdrive:backups/ml-train-server check
   ```

2. **List recent snapshots**
   ```bash
   restic -r gdrive:backups/ml-train-server snapshots
   ```

3. **Perform test restore**
   ```bash
   mkdir -p /tmp/backup-test
   restic -r gdrive:backups/ml-train-server restore latest \
     --target /tmp/backup-test \
     --path /mnt/storage/homes/alice/test-file

   # Verify file contents
   cat /tmp/backup-test/mnt/storage/homes/alice/test-file

   # Cleanup
   rm -rf /tmp/backup-test
   ```

4. **Check healthchecks.io**
   - Visit healthchecks.io dashboard
   - Verify backup job pinging successfully

5. **Review Telegram alerts**
   - Check for backup success notifications

**Time estimate:** 10 minutes

**Schedule:** Monthly automated test recommended

---

### Changing Backup Schedule

**When:** Adjusting backup frequency or timing.

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Change backup time
   BACKUP_HOUR=2    # Was: 6 (2 AM instead of 6 AM)
   BACKUP_MINUTE=30 # Was: 0
   ```

2. **Re-run backup setup**
   ```bash
   sudo ./scripts/09-setup-backups.sh
   # This updates cron jobs
   ```

3. **Verify cron schedule**
   ```bash
   sudo crontab -l | grep backup
   ```

4. **Test manual trigger**
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

**Time estimate:** 5 minutes

---

### Migrating to New Backup Destination

**When:** Changing from GDrive to S3, or different cloud provider.

**Steps:**

1. **Configure new rclone remote**
   ```bash
   rclone config
   # Create new remote (e.g., "s3-backup")
   ```

2. **Test new remote**
   ```bash
   rclone lsd s3-backup:
   ```

3. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   BACKUP_REMOTE="s3-backup:ml-train-server-backups"  # Was: gdrive:backups/ml-train-server
   ```

4. **Initialize new Restic repository**
   ```bash
   restic -r s3-backup:ml-train-server-backups init
   ```

5. **Perform first backup to new destination**
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

6. **Verify backup**
   ```bash
   restic -r s3-backup:ml-train-server-backups snapshots
   ```

7. **Optional: Copy old backups to new destination**
   ```bash
   # This requires advanced Restic usage
   # Easier to just start fresh with new backups
   ```

8. **Keep old backups accessible** (for historical restores)

**Time estimate:** 30 minutes + first backup time

---