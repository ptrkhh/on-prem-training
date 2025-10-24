

## Security Operations

### Rotating Service Passwords

**When:** Security audit, suspected compromise, or regular maintenance (quarterly).

**Services to update:**
- Grafana admin
- Portainer admin
- User container passwords
- Database passwords (if added)

**Steps:**

1. **Grafana password**
   ```bash
   docker exec -it grafana grafana-cli admin reset-admin-password newpassword123
   ```

2. **Portainer password**
   ```bash
   # Via UI: Settings → Users → admin → Change password
   # Or reset via CLI:
   docker exec -it portainer /portainer --admin-password='newpassword'
   ```

3. **User container passwords**
   ```bash
   # For each user
   docker exec -it workspace-alice passwd alice
   ```

4. **Update .env file** (if using environment variables)
   ```bash
   nano ~/train-server/docker/.env

   GRAFANA_ADMIN_PASSWORD=newpassword123
   PORTAINER_ADMIN_PASSWORD=newpassword456
   ```

5. **Restart affected services**
   ```bash
   cd ~/train-server/docker
   docker compose restart grafana portainer
   ```

6. **Notify users** (if their passwords were changed)

7. **Document password change** (in secure location)

**Time estimate:** 15 minutes

---

### Updating Firewall Rules

**When:** Security hardening, new services, or access changes.

**Steps:**

1. **List current rules**
   ```bash
   sudo ufw status numbered
   ```

2. **Add new rule**
   ```bash
   # Allow specific port
   sudo ufw allow 8443/tcp

   # Allow from specific IP
   sudo ufw allow from 203.0.113.50 to any port 22

   # Allow subnet
   sudo ufw allow from 192.168.1.0/24
   ```

3. **Delete rule**
   ```bash
   # By number
   sudo ufw delete 3

   # By specification
   sudo ufw delete allow 8443/tcp
   ```

4. **Block specific IP**
   ```bash
   sudo ufw deny from 198.51.100.100
   ```

5. **Default policies**
   ```bash
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   ```

6. **Reload firewall**
   ```bash
   sudo ufw reload
   ```

7. **Verify rules**
   ```bash
   sudo ufw status verbose
   ```

**Common rules for this setup:**
```bash
sudo ufw allow 22/tcp      # SSH (if not using Cloudflare Tunnel only)
sudo ufw allow 80/tcp      # HTTP (for Traefik)
sudo ufw allow 443/tcp     # HTTPS (if using direct access)
sudo ufw allow 2222/tcp    # User SSH
sudo ufw allow 4000:4010/tcp  # NoMachine (adjust range for user count)
```

**Time estimate:** 10 minutes

---

### Reviewing Access Logs

**When:** Security audit, investigating suspicious activity, or compliance.

**Steps:**

1. **SSH access logs**
   ```bash
   sudo grep sshd /var/log/auth.log | tail -50

   # Failed login attempts
   sudo grep "Failed password" /var/log/auth.log

   # Successful logins
   sudo grep "Accepted password" /var/log/auth.log
   ```

2. **Docker container logs**
   ```bash
   docker logs workspace-alice --since 24h | grep -i error
   docker logs traefik --since 24h | grep -i "status=401\|status=403"
   ```

3. **Traefik access logs**
   ```bash
   docker logs traefik | grep -E "GET|POST" | tail -100
   ```

4. **Netdata audit logs**
   ```bash
   # Via UI: http://server_ip:19999 → Logs section
   ```

5. **System authentication logs**
   ```bash
   sudo lastlog  # Last login for all users
   sudo last     # Recent logins
   sudo lastb    # Failed login attempts
   ```

6. **Find brute force attempts**
   ```bash
   sudo grep "Failed password" /var/log/auth.log | awk '{print $11}' | sort | uniq -c | sort -rn
   ```

7. **Export logs for analysis**
   ```bash
   sudo journalctl --since "2025-01-01" --until "2025-01-24" > /tmp/system-logs.txt
   ```

**Automation:**
```bash
# Daily security report via cron
0 8 * * * /opt/scripts/security/generate-daily-report.sh | mail -s "Security Report" admin@yourdomain.com
```

**Time estimate:** 15 minutes

---

### Enabling Audit Logging

**When:** Compliance requirements, enhanced security monitoring, or forensic capabilities.

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh
   ENABLE_AUDITD=true
   ```

2. **Install auditd**
   ```bash
   sudo apt install -y auditd audispd-plugins
   ```

3. **Configure audit rules**
   ```bash
   sudo nano /etc/audit/rules.d/custom.rules
   ```

   Add:
   ```
   # Monitor /mnt/storage writes
   -w /mnt/storage/homes -p wa -k homes-write
   -w /mnt/storage/workspaces -p wa -k workspaces-write

   # Monitor user actions
   -w /etc/passwd -p wa -k passwd-changes
   -w /etc/sudoers -p wa -k sudoers-changes

   # Monitor Docker
   -w /var/lib/docker/ -p wa -k docker-changes
   ```

4. **Reload audit rules**
   ```bash
   sudo augenrules --load
   sudo systemctl restart auditd
   ```

5. **View audit logs**
   ```bash
   sudo ausearch -k homes-write
   sudo ausearch -k passwd-changes

   # All recent events
   sudo ausearch -ts recent
   ```

6. **Generate audit report**
   ```bash
   sudo aureport --summary
   sudo aureport --auth
   ```

**Warning:** Audit logging increases disk I/O and log sizes.

**Time estimate:** 20 minutes

---

### Responding to Quota Violations

**When:** User exceeds storage quota, impacting system performance.

**Steps:**

1. **Identify violation**
   ```bash
   sudo btrfs qgroup show /mnt/storage
   # Look for users exceeding USER_QUOTA_GB

   # Detailed breakdown
   sudo du -sh /mnt/storage/homes/*
   sudo du -sh /mnt/storage/workspaces/*
   ```

2. **Analyze user's storage**
   ```bash
   docker exec workspace-alice du -sh /home/alice/* | sort -h | tail -20
   docker exec workspace-alice du -sh /workspace/* | sort -h | tail -20

   # Find large files
   docker exec workspace-alice find /home/alice -type f -size +1G -exec ls -lh {} \;
   docker exec workspace-alice find /workspace -type f -size +10G -exec ls -lh {} \;
   ```

3. **Notify user**
   ```
   Subject: Storage Quota Exceeded - Action Required

   Hi Alice,

   Your storage usage has exceeded the 1TB quota:
   - Home: 150GB
   - Workspace: 920GB
   - Total: 1070GB / 1000GB

   Please review and delete unnecessary files:
   - Old model checkpoints: /workspace/experiments/
   - Downloaded datasets: /workspace/data/
   - Large log files

   Top 10 largest files:
   [paste output from above]

   Target: Reduce to under 800GB within 48 hours.
   ```

4. **Temporary measures**
   ```bash
   # Read-only mode (emergency)
   docker exec workspace-alice mount -o remount,ro /workspace

   # Suspend container
   docker pause workspace-alice
   ```

5. **Assist user with cleanup**
   ```bash
   # Clear old Docker images
   docker exec workspace-alice docker system prune -a --volumes -f

   # Clear pip cache
   docker exec workspace-alice rm -rf /home/alice/.cache/pip

   # Clear conda packages
   docker exec workspace-alice conda clean --all -y
   ```

6. **Verify compliance**
   ```bash
   sudo du -sh /mnt/storage/homes/alice /mnt/storage/workspaces/alice
   ```

7. **Restore access**
   ```bash
   docker unpause workspace-alice
   docker exec workspace-alice mount -o remount,rw /workspace
   ```

8. **If user cannot comply, consider:**
   - Increase quota (if capacity allows)
   - Archive old data to external storage
   - Temporary workspace expansion

**Time estimate:** 30 minutes - 2 hours (depending on user cooperation)

---