

## Troubleshooting

### Container Won't Start

**Symptoms:** Container exits immediately, stuck in restart loop.

**Steps:**

1. **Check container status**
   ```bash
   docker ps -a | grep workspace-alice
   ```

2. **View logs**
   ```bash
   docker logs workspace-alice --tail 100
   ```

3. **Check for port conflicts**
   ```bash
   sudo netstat -tulpn | grep -E "4000|8080"
   ```

4. **Inspect container**
   ```bash
   docker inspect workspace-alice
   ```

5. **Common issues:**

   **Port already in use:**
   ```bash
   # Kill process using port
   sudo lsof -ti:4000 | xargs sudo kill -9
   docker compose start workspace-alice
   ```

   **Permission issues:**
   ```bash
   sudo chown -R 1000:1000 /mnt/storage/homes/alice
   docker compose restart workspace-alice
   ```

   **Corrupted container:**
   ```bash
   docker compose stop workspace-alice
   docker compose rm -f workspace-alice
   docker compose up -d workspace-alice
   ```

6. **Rebuild if needed**
   ```bash
   docker compose build --no-cache workspace-alice
   docker compose up -d workspace-alice
   ```

**Time estimate:** 10-30 minutes

---

### Remote Desktop Connection Failed

**Symptoms:** Can't connect to user's desktop via Guacamole, Kasm, VNC, or RDP.

**Steps:**

1. **Verify container is running**
   ```bash
   docker ps | grep workspace-alice
   ```

2. **Check desktop services inside container**
   ```bash
   # Check VNC server
   docker exec workspace-alice ps aux | grep vnc

   # Check XRDP
   docker exec workspace-alice ps aux | grep xrdp

   # Check supervisord (manages all services)
   docker exec workspace-alice supervisorctl status
   ```

3. **Check port mappings**
   ```bash
   # VNC port
   docker port workspace-alice 5900

   # RDP port
   docker port workspace-alice 3389

   # noVNC (web) port
   docker port workspace-alice 6080
   ```

4. **Test web access via Guacamole**
   - Access: `http://guacamole.${DOMAIN}` or `http://remote.${DOMAIN}`
   - Login with Guacamole default credentials: `guacadmin` / `guacadmin`
   - Check if user connections are configured

5. **Test web access via noVNC**
   - Access: `http://alice-desktop.${DOMAIN}` or `http://alice.${DOMAIN}`
   - Should see desktop in browser

6. **Test Kasm Workspaces**
   - Access: `http://kasm.${DOMAIN}`
   - Login and check workspace availability

7. **Restart services inside container**
   ```bash
   docker exec workspace-alice supervisorctl restart all
   ```

8. **Check Traefik routing**
   ```bash
   # Check Traefik dashboard
   curl http://localhost:8080/api/http/routers | jq

   # Check if alice's routes are registered
   docker logs traefik | grep alice
   ```

9. **Recreate container if needed**
   ```bash
   docker compose restart workspace-alice
   ```

**Time estimate:** 10 minutes

---

### Slow Storage Performance

**Symptoms:** High I/O wait, slow file operations, laggy system.

**Steps:**

1. **Check disk I/O**
   ```bash
   iostat -x 5 3
   # Look for high %util
   ```

2. **Check BTRFS status**
   ```bash
   sudo btrfs filesystem df /mnt/storage
   sudo btrfs filesystem usage /mnt/storage

   # If >95% full, performance degrades
   ```

3. **Check for failing disk**
   ```bash
   sudo btrfs device stats /mnt/storage
   sudo smartctl -a /dev/sdb | grep -i fail

   # Look for non-zero error counts
   ```

4. **Check bcache state**
   ```bash
   cat /sys/block/bcache0/bcache/state
   # Should be: clean

   cat /sys/block/bcache0/bcache/dirty_data
   # If very high, cache is flushing
   ```

5. **Balance filesystem**
   ```bash
   sudo btrfs balance start -dusage=30 /mnt/storage
   ```

6. **Run scrub**
   ```bash
   sudo btrfs scrub start /mnt/storage
   sudo btrfs scrub status /mnt/storage
   ```

7. **Check for processes causing high I/O**
   ```bash
   sudo iotop -o
   ```

8. **Defragment**
   ```bash
   sudo btrfs filesystem defragment -r /mnt/storage/homes
   ```

**Prevention:** Keep filesystem <90% full, regular scrubs, monitor SMART

**Time estimate:** 1-4 hours (balance/scrub runs in background)

---

### GPU Not Detected

**Symptoms:** `nvidia-smi` fails in container, training code can't find GPU.

**Steps:**

1. **Check GPU on host**
   ```bash
   nvidia-smi
   # Should show GPU
   ```

2. **Check NVIDIA driver**
   ```bash
   nvidia-smi | grep "Driver Version"

   # Update if needed
   sudo apt update
   sudo apt install -y nvidia-driver-555
   sudo reboot
   ```

3. **Check NVIDIA Docker runtime**
   ```bash
   docker run --rm --gpus all nvidia/cuda:12.4.0-base nvidia-smi
   ```

4. **Check container GPU access**
   ```bash
   docker exec workspace-alice nvidia-smi
   ```

5. **If GPU not visible in container:**
   ```bash
   # Restart container
   docker compose restart workspace-alice

   # Check docker-compose.yml has GPU config
   nano ~/train-server/docker/docker-compose.yml
   # Should have:
   #   deploy:
   #     resources:
   #       reservations:
   #         devices:
   #           - driver: nvidia
   #             capabilities: [gpu]
   ```

6. **Recreate container with GPU**
   ```bash
   cd ~/train-server/docker
   docker compose up -d --force-recreate workspace-alice
   ```

7. **Verify CUDA in Python**
   ```bash
   docker exec workspace-alice python3 -c "import torch; print(torch.cuda.is_available())"
   ```

**Time estimate:** 15 minutes

---

### High Memory Usage

**Symptoms:** System slow, OOM killer activating, containers being killed.

**Steps:**

1. **Check overall memory**
   ```bash
   free -h
   htop
   ```

2. **Check container memory usage**
   ```bash
   docker stats --no-stream
   ```

3. **Check processes in high-memory container**
   ```bash
   docker exec workspace-alice ps aux --sort=-%mem | head -20
   ```

4. **Check for memory leaks**
   ```bash
   docker exec workspace-alice top -o %MEM
   ```

5. **Restart high-memory container**
   ```bash
   docker compose restart workspace-alice
   ```

6. **Adjust container memory limits** (if needed)
   ```bash
   nano ~/train-server/config.sh
   MEMORY_LIMIT_GB=80  # Reduce from 100

   cd docker
   ./generate-compose.sh
   docker compose up -d --force-recreate
   ```

7. **Check for disk caching issues**
   ```bash
   sudo sync
   sudo sysctl vm.drop_caches=3
   ```

8. **Notify user to optimize code**
   - Release unused tensors
   - Use gradient checkpointing
   - Reduce batch size

**Time estimate:** 15 minutes

---

### Network Connectivity Issues

**Symptoms:** Can't access web services, Cloudflare Tunnel down, SSH not working.

**Steps:**

1. **Check internet connectivity**
   ```bash
   ping -c 4 8.8.8.8
   ping -c 4 google.com
   ```

2. **Check Cloudflare Tunnel**
   ```bash
   sudo systemctl status cloudflared
   sudo journalctl -u cloudflared -n 50

   # Restart if needed
   sudo systemctl restart cloudflared
   ```

3. **Check Traefik**
   ```bash
   docker logs traefik --tail 50
   docker compose restart traefik
   ```

4. **Check port accessibility**
   ```bash
   # From external machine
   telnet server_ip 80
   telnet server_ip 2222
   telnet server_ip 4000
   ```

5. **Check firewall**
   ```bash
   sudo ufw status verbose

   # Temporarily disable to test
   sudo ufw disable
   # Test connection
   sudo ufw enable
   ```

6. **Check DNS**
   ```bash
   nslookup alice-code.yourdomain.com
   dig alice-code.yourdomain.com
   ```

7. **Check routes**
   ```bash
   ip route
   netstat -rn
   ```

8. **Test local access**
   ```bash
   curl http://localhost/health
   curl http://localhost:19999  # Netdata
   ```

9. **Restart network services**
   ```bash
   sudo systemctl restart networking
   sudo systemctl restart systemd-networkd
   ```

**Time estimate:** 20 minutes

---