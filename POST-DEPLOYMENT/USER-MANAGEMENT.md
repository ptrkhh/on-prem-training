
## User Management

### Adding a New User

**When:** New team member joins or need to provision additional workspace.

**Steps:**

1. **Update configuration**
   ```bash
   cd ~/train-server
   nano config.sh

   # Add new username to USERS list
   # Before: USERS="alice bob charlie"
   # After:  USERS="alice bob charlie frank"
   ```

2. **Validate configuration**
   ```bash
   ./scripts/00-validate-config.sh
   ```

3. **Create system user**
   ```bash
   sudo ./scripts/04-setup-users.sh
   # This will create: /home/frank, /mnt/storage/homes/frank, /mnt/storage/workspaces/frank
   ```

4. **Regenerate docker-compose.yml**
   ```bash
   cd docker
   ./generate-compose.sh
   ```

5. **Build and start new container**
   ```bash
   docker compose build workspace-frank
   docker compose up -d workspace-frank
   ```

6. **Verify access**
   ```bash
   # Check container is running
   docker ps | grep workspace-frank

   # Check VNC port (e.g., 5903 for 4th user)
   ss -tulpn | grep 5903

   # Check RDP port (e.g., 3392 for 4th user)
   ss -tulpn | grep 3392

   # Check noVNC web port (e.g., 6083 for 4th user)
   ss -tulpn | grep 6083

   # Test SSH access
   ssh frank@localhost -p 2225
   ```

7. **Provide credentials to user**
   - Web Desktop (noVNC): `http://frank-desktop.yourdomain.com` or `http://frank.yourdomain.com`
   - Guacamole: `http://guacamole.yourdomain.com` or `http://remote.yourdomain.com`
   - Kasm Workspaces: `http://kasm.yourdomain.com`
   - Direct VNC: `server_ip:5903` (adjust port based on user index)
   - Direct RDP: `server_ip:3392` (adjust port based on user index)
   - SSH: `ssh frank@server_ip -p 2225` (adjust port based on user index)
   - VS Code: `http://frank-code.yourdomain.com`
   - Jupyter: `http://frank-jupyter.yourdomain.com`
   - Password: Set during user creation or provide initial password

**Time estimate:** 10-15 minutes

---

### Removing a User

**When:** Team member leaves or workspace no longer needed.

**Steps:**

1. **Notify user to backup important data** (if applicable)

2. **Stop and remove container**
   ```bash
   cd ~/train-server/docker
   docker compose stop workspace-frank
   docker compose rm -f workspace-frank
   ```

3. **Archive or delete user data**
   ```bash
   # Option A: Archive to external storage
   sudo mkdir -p /mnt/archive
   sudo mv /mnt/storage/homes/frank /mnt/archive/frank-home-$(date +%Y%m%d)
   sudo mv /mnt/storage/workspaces/frank /mnt/archive/frank-workspace-$(date +%Y%m%d)

   # Option B: Permanent deletion (WARNING: irreversible!)
   sudo btrfs subvolume delete /mnt/storage/homes/frank
   sudo btrfs subvolume delete /mnt/storage/workspaces/frank
   ```

4. **Remove system user**
   ```bash
   sudo userdel -r frank
   ```

5. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Remove username from USERS list
   # Before: USERS="alice bob charlie frank"
   # After:  USERS="alice bob charlie"
   ```

6. **Regenerate docker-compose.yml**
   ```bash
   cd ~/train-server/docker
   ./generate-compose.sh
   ```

7. **Clean up docker resources**
   ```bash
   docker volume rm ml-train-server_frank-docker-data 2>/dev/null || true
   docker network prune -f
   ```

**Storage reclaimed:** ~1TB (USER_QUOTA_GB per user)

**Time estimate:** 10 minutes

---

### Modifying User Resources

**When:** User needs more RAM, different memory limits, or adjusted quotas.

**Scenarios:**
- Increase RAM for memory-intensive workloads
- Decrease RAM to accommodate more users
- Adjust storage quota

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Adjust these values:
   MEMORY_GUARANTEE_GB=64    # Was: 32
   MEMORY_LIMIT_GB=150       # Was: 100
   USER_QUOTA_GB=2000        # Was: 1000
   ```

2. **Regenerate docker-compose.yml**
   ```bash
   cd ~/train-server/docker
   ./generate-compose.sh
   ```

3. **Recreate affected containers**
   ```bash
   # Option A: Single user
   docker compose up -d --force-recreate workspace-alice

   # Option B: All users
   docker compose up -d --force-recreate
   ```

4. **Verify new limits**
   ```bash
   # Check memory limits
   docker inspect workspace-alice | grep -A 10 Memory

   # Check storage quota (manual verification)
   sudo btrfs qgroup show /mnt/storage
   ```

**Note:** Containers will restart (save work first!)

**Time estimate:** 5 minutes per user

---

### Resetting User Password

**When:** User forgets password or security incident requires password change.

**Steps:**

1. **Access user container**
   ```bash
   docker exec -it workspace-alice bash
   ```

2. **Reset password inside container**
   ```bash
   passwd alice
   # Enter new password twice
   ```

3. **Update host system password (for SSH)**
   ```bash
   # On host
   sudo passwd alice
   ```

4. **Notify user of new password**

**Alternative method (without entering container):**
```bash
# Set password directly
echo "alice:newpassword123" | docker exec -i workspace-alice chpasswd
sudo echo "alice:newpassword123" | chpasswd
```

**Time estimate:** 2 minutes

---

### Temporarily Suspending a User

**When:** User on leave, temporary access restriction, or resource reallocation.

**Steps:**

1. **Stop user container (preserves data)**
   ```bash
   docker compose stop workspace-alice
   ```

2. **Optional: Lock system account**
   ```bash
   sudo usermod -L alice
   ```

3. **To resume access later**
   ```bash
   # Start container
   docker compose start workspace-alice

   # Unlock account if locked
   sudo usermod -U alice
   ```

**Storage note:** Data remains intact, snapshots continue

**Time estimate:** 1 minute

---