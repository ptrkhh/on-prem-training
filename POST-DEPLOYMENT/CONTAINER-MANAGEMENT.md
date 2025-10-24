
## Container Management

### Restarting a User Container

**When:** User experiencing issues, applying configuration changes, or troubleshooting.

**Steps:**

1. **Notify user** (save work first!)

2. **Restart container**
   ```bash
   cd ~/train-server/docker
   docker compose restart workspace-alice
   ```

3. **Verify container is running**
   ```bash
   docker ps | grep workspace-alice
   ```

4. **Check logs for errors**
   ```bash
   docker logs workspace-alice --tail 50
   ```

5. **Notify user to reconnect**

**Time estimate:** 1 minute

---

### Rebuilding All Containers

**When:** Major updates, Dockerfile changes, or troubleshooting persistent issues.

**Steps:**

1. **Notify all users** (schedule during maintenance window)

2. **Backup current state** (optional)
   ```bash
   docker compose ps > ~/container-state-backup.txt
   ```

3. **Stop all containers**
   ```bash
   cd ~/train-server/docker
   docker compose down
   ```

4. **Rebuild images**
   ```bash
   docker compose build --no-cache
   ```

5. **Start all containers**
   ```bash
   docker compose up -d
   ```

6. **Verify all containers running**
   ```bash
   docker compose ps
   docker ps --format "table {{.Names}}\t{{.Status}}"
   ```

7. **Test each user**
   ```bash
   for user in alice bob charlie dave eve; do
       docker exec workspace-$user echo "OK: $user"
   done
   ```

8. **Notify users to reconnect**

**Time estimate:** 30-60 minutes

---

### Clearing Container Logs

**When:** Logs consuming too much disk space.

**Steps:**

1. **Check log sizes**
   ```bash
   sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -h
   ```

2. **Clear logs for specific container**
   ```bash
   # Method A: Truncate log file
   sudo truncate -s 0 $(docker inspect --format='{{.LogPath}}' workspace-alice)

   # Method B: Using docker
   docker logs workspace-alice --tail 0 > /dev/null 2>&1
   ```

3. **Clear all container logs**
   ```bash
   cd ~/train-server/docker
   docker compose down
   sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log
   docker compose up -d
   ```

4. **Configure log rotation** (permanent fix)
   ```bash
   sudo nano /etc/docker/daemon.json
   ```

   Add:
   ```json
   {
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "10m",
       "max-file": "3"
     }
   }
   ```

   ```bash
   sudo systemctl restart docker
   cd ~/train-server/docker
   docker compose up -d
   ```

**Time estimate:** 5 minutes

---

### Accessing Container Shell

**When:** Troubleshooting, debugging, or manual inspection.

**Steps:**

1. **As container user**
   ```bash
   docker exec -it workspace-alice bash
   ```

2. **As root inside container**
   ```bash
   docker exec -it --user root workspace-alice bash
   ```

3. **Run single command**
   ```bash
   docker exec workspace-alice ps aux
   docker exec workspace-alice nvidia-smi
   docker exec workspace-alice df -h
   ```

4. **Check environment**
   ```bash
   docker exec workspace-alice env
   ```

5. **Exit container shell**
   ```bash
   exit
   ```

**Time estimate:** Instant

---

### Container Resource Usage Check

**When:** Investigating performance issues or capacity planning.

**Steps:**

1. **Real-time stats**
   ```bash
   docker stats
   # Shows CPU, RAM, network I/O for all containers
   ```

2. **Per-container details**
   ```bash
   docker stats workspace-alice --no-stream
   ```

3. **Memory breakdown**
   ```bash
   docker exec workspace-alice free -h
   docker exec workspace-alice ps aux --sort=-%mem | head -n 10
   ```

4. **GPU usage**
   ```bash
   docker exec workspace-alice nvidia-smi
   ```

5. **Disk usage inside container**
   ```bash
   docker exec workspace-alice df -h
   docker exec workspace-alice du -sh /home/alice/* | sort -h
   ```

6. **Network connections**
   ```bash
   docker exec workspace-alice netstat -tuln
   ```

**Time estimate:** 2 minutes

---