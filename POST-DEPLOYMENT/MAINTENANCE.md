

## Maintenance Tasks

### Ubuntu System Updates

**When:** Monthly security updates, or after security advisories.

**Steps:**

1. **Notify users of upcoming maintenance**
   ```
   Subject: System Maintenance - [Date/Time]

   Server will undergo system updates.
   Expected downtime: 15-30 minutes
   Please save your work.
   ```

2. **Backup critical data** (precaution)
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

3. **Update package list**
   ```bash
   sudo apt update
   ```

4. **Check available updates**
   ```bash
   sudo apt list --upgradable
   ```

5. **Perform updates**
   ```bash
   sudo apt upgrade -y
   sudo apt full-upgrade -y
   sudo apt autoremove -y
   sudo apt autoclean
   ```

6. **Update NVIDIA drivers** (if available)
   ```bash
   sudo apt upgrade -y nvidia-driver-555
   # Check version: nvidia-smi
   ```

7. **Reboot if kernel updated**
   ```bash
   # Check if reboot needed
   [ -f /var/run/reboot-required ] && echo "Reboot required"

   sudo reboot
   ```

8. **After reboot, verify services**
   ```bash
   cd ~/train-server/docker
   docker compose ps
   sudo systemctl status cloudflared
   mount | grep /mnt/storage
   nvidia-smi
   ```

9. **Enable automatic security updates** (optional)
   ```bash
   sudo apt install -y unattended-upgrades
   sudo dpkg-reconfigure -plow unattended-upgrades
   ```

**Schedule:** Monthly, or immediately after critical security patches

**Time estimate:** 30-60 minutes

---

### Docker Cleanup

**When:** Disk space low, or monthly maintenance.

**Steps:**

1. **Check Docker disk usage**
   ```bash
   docker system df
   ```

2. **Remove unused containers**
   ```bash
   docker container prune -f
   ```

3. **Remove unused images**
   ```bash
   docker image prune -a -f
   ```

4. **Remove unused volumes**
   ```bash
   docker volume prune -f
   ```

5. **Remove unused networks**
   ```bash
   docker network prune -f
   ```

6. **All-in-one cleanup**
   ```bash
   docker system prune -a --volumes -f
   ```

7. **Verify disk space reclaimed**
   ```bash
   docker system df
   df -h /var/lib/docker
   ```

**Automate:**
```bash
# Add to crontab (run weekly)
0 2 * * 0 docker system prune -a -f --volumes
```

**Warning:** This removes ALL unused images. User containers will need rebuilding if stopped.

**Time estimate:** 10 minutes

---

### Log Rotation and Cleanup

**When:** Logs consuming too much space, or quarterly maintenance.

**Steps:**

1. **Check log sizes**
   ```bash
   sudo du -sh /var/log/*
   sudo du -sh /var/lib/docker/containers/*/*-json.log
   ```

2. **Configure logrotate for system logs**
   ```bash
   sudo nano /etc/logrotate.d/custom
   ```

   Add:
   ```
   /var/log/syslog {
       daily
       rotate 7
       compress
       delaycompress
       missingok
       notifnotifempty
   }

   /opt/scripts/*/logs/*.log {
       weekly
       rotate 4
       compress
       missingok
       notifempty
   }
   ```

3. **Force log rotation**
   ```bash
   sudo logrotate -f /etc/logrotate.conf
   ```

4. **Clear old logs manually**
   ```bash
   sudo find /var/log -type f -name "*.log.*" -mtime +30 -delete
   sudo find /var/log -type f -name "*.gz" -mtime +60 -delete
   ```

5. **Clear journal logs**
   ```bash
   # Keep only 7 days
   sudo journalctl --vacuum-time=7d

   # Or limit size to 500MB
   sudo journalctl --vacuum-size=500M
   ```

6. **Configure journal retention**
   ```bash
   sudo nano /etc/systemd/journald.conf

   # Uncomment and set:
   SystemMaxUse=500M
   MaxRetentionSec=7day

   sudo systemctl restart systemd-journald
   ```

7. **Docker log cleanup** (see "Clearing Container Logs" section)

**Time estimate:** 15 minutes

---

### Database Maintenance (Prometheus)

**When:** Prometheus disk usage high, or quarterly maintenance.

**Steps:**

1. **Check Prometheus disk usage**
   ```bash
   docker exec prometheus df -h /prometheus
   ```

2. **Check retention settings**
   ```bash
   docker logs prometheus 2>&1 | grep retention
   ```

3. **Update Prometheus retention**
   ```bash
   nano ~/train-server/docker/docker-compose.yml

   # Find prometheus service, add/modify:
   command:
     - '--storage.tsdb.retention.time=30d'  # Was: 90d
     - '--storage.tsdb.retention.size=50GB'  # Or size limit
   ```

4. **Restart Prometheus**
   ```bash
   docker compose restart prometheus
   ```

5. **Manual cleanup (if needed)**
   ```bash
   # Delete old data
   docker exec prometheus rm -rf /prometheus/data/chunks_head/*
   ```

6. **Verify Prometheus running**
   ```bash
   curl http://localhost:9090/-/healthy
   ```

**Time estimate:** 10 minutes

---

### Scheduled Downtime

**When:** Major hardware changes, extensive maintenance, or migrations.

**Steps:**

1. **Plan maintenance window**
   - Choose low-usage time (weekend, night)
   - Allocate 2x estimated time
   - Prepare rollback plan

2. **Notify users (1 week in advance)**
   ```
   Subject: Scheduled Maintenance - [Date/Time]

   Server will undergo scheduled maintenance:
   - Date: Saturday, Feb 3, 2025
   - Time: 2:00 AM - 6:00 AM PST
   - Duration: Up to 4 hours
   - Reason: Hardware upgrade / System updates

   Impact:
   - All services will be unavailable
   - Web desktop, Guacamole, and Kasm access disabled
   - SSH, VNC, and RDP access disabled
   - Save your work before maintenance window

   We will send updates via Telegram/Email.
   ```

3. **Send reminder (24 hours before)**

4. **Send final warning (1 hour before)**

5. **Pre-maintenance backup**
   ```bash
   sudo /opt/scripts/backup/run-restic-backup.sh
   ```

6. **Gracefully stop services**
   ```bash
   cd ~/train-server/docker
   docker compose stop

   sudo systemctl stop cloudflared
   sudo systemctl stop rclone-gdrive-shared
   ```

7. **Perform maintenance**
   - Follow specific maintenance guides
   - Document all changes
   - Test each component before proceeding

8. **Verify everything works**
   ```bash
   docker compose ps
   nvidia-smi
   df -h
   ./scripts/11-run-tests.sh
   ```

9. **Notify users of completion**
   ```
   Subject: Maintenance Complete

   Server maintenance completed successfully.
   All services are now available.

   Changes made:
   - [List changes]

   Please report any issues.
   ```

10. **Monitor for 24 hours**
    - Check alerts
    - Review logs
    - Respond to user reports

**Time estimate:** Varies by task

---