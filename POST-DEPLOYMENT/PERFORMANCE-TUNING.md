# Performance Tuning Guide

**Documentation**: [README](../README.md) > [Setup Guide](../SETUP-GUIDE.md) > [Operations](./README.md) > Performance Tuning

---

## Performance Tuning

### Adjusting bcache Settings

**When:** Optimizing for read-heavy vs write-heavy workloads.

**Steps:**

1. **Check current settings**
   ```bash
   cat /sys/block/bcache0/bcache/cache_mode
   cat /sys/block/bcache0/bcache/sequential_cutoff
   cat /sys/block/bcache0/bcache/writeback_percent
   ```

2. **Change cache mode**
   ```bash
   # Options: writeback, writethrough, writearound, none
   echo writeback | sudo tee /sys/block/bcache*/bcache/cache_mode
   ```

3. **Adjust writeback threshold** (only for writeback mode)
   ```bash
   # Percentage of dirty data before flushing (0-100)
   echo 50 | sudo tee /sys/block/bcache*/bcache/writeback_percent
   ```

4. **Adjust sequential cutoff**
   ```bash
   # Skip caching for sequential I/O larger than this (in KB)
   # 0 = cache everything, 4096 = skip sequential >4MB
   echo 4096 | sudo tee /sys/block/bcache*/bcache/sequential_cutoff
   ```

5. **Make permanent** (add to startup script)
   ```bash
   sudo nano /etc/rc.local

   # Add:
   echo writeback > /sys/block/bcache0/bcache/cache_mode
   echo 50 > /sys/block/bcache0/bcache/writeback_percent
   ```

6. **Monitor cache hit ratio**
   ```bash
   cat /sys/block/bcache0/bcache/stats_total/cache_hit_ratio
   # Higher is better (90+ = excellent)
   ```

**Recommendations:**
- **Read-heavy:** writeback mode, low writeback_percent (10-30)
- **Write-heavy:** writethrough or writeback, high writeback_percent (70-90)
- **Mixed:** writeback mode, medium writeback_percent (40-60)

**Time estimate:** 10 minutes

---

### Optimizing BTRFS Performance

**When:** Storage feels slow, high latency, or fragmentation suspected.

**Steps:**

1. **Check fragmentation**
   ```bash
   sudo btrfs filesystem defragment -r -v /mnt/storage
   ```

2. **Adjust mount options**
   ```bash
   sudo nano /etc/fstab

   # Add mount options:
   UUID=xxx /mnt/storage btrfs defaults,noatime,compress=zstd:3,ssd,space_cache=v2 0 0

   # Options explained:
   # noatime     - Don't update access times (faster)
   # compress    - Enable compression
   # ssd         - SSD-specific optimizations
   # space_cache - Faster free space calculations

   sudo mount -o remount /mnt/storage
   ```

3. **Balance filesystem** (reclaim space, reduce fragmentation)
   ```bash
   # Light balance (usage <30%)
   sudo btrfs balance start -dusage=30 -musage=30 /mnt/storage

   # Full balance (slow, only if needed)
   sudo btrfs balance start /mnt/storage
   ```

4. **Enable auto-defrag**
   ```bash
   sudo nano /etc/fstab
   # Add autodefrag to mount options:
   UUID=xxx /mnt/storage btrfs defaults,noatime,autodefrag 0 0

   sudo mount -o remount /mnt/storage
   ```

5. **Check for errors**
   ```bash
   sudo btrfs device stats /mnt/storage
   sudo btrfs scrub start /mnt/storage
   ```

**Time estimate:** 30 minutes - 6 hours (balance/defrag runs in background)

---

### GPU Memory Optimization

**When:** Out-of-memory errors, multiple users sharing GPU, or maximizing throughput.

**Steps:**

1. **Check GPU memory usage**
   ```bash
   nvidia-smi
   # Look at Memory-Usage column
   ```

2. **Enable GPU timeslicing** (share GPU across containers)
   ```bash
   nano ~/train-server/config.sh
   ENABLE_GPU_TIMESLICING=true

   sudo ./scripts/05-setup-docker.sh
   cd ~/train-server/docker
   docker compose restart
   ```

3. **Configure timeslicing intervals**
   ```bash
   sudo nano /etc/nvidia-container-runtime/config.toml

   # Add:
   [nvidia-container-runtime]
   mode = "auto"

   [nvidia-container-runtime.gpu]
   shared-policy = "time-slicing"
   time-slice-duration = "50ms"  # Adjust: 10ms-100ms
   ```

4. **Per-container GPU memory limits**
   ```bash
   nano ~/train-server/docker/docker-compose.yml

   # Add to user service:
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             device_ids: ['0']
             capabilities: [gpu]
             options:
               memory: 8GB  # Limit GPU memory per container
   ```

5. **Monitor GPU memory**
   ```bash
   watch -n 1 nvidia-smi
   ```

**User-side optimization:**
```python
# In user's code, limit TensorFlow GPU memory growth
import tensorflow as tf
gpus = tf.config.experimental.list_physical_devices('GPU')
for gpu in gpus:
    tf.config.experimental.set_memory_growth(gpu, True)

# PyTorch: Use torch.cuda.set_per_process_memory_fraction()
import torch
torch.cuda.set_per_process_memory_fraction(0.5, 0)  # Use max 50% GPU memory
```

**Time estimate:** 15 minutes

---

### Network Bandwidth Limits

**When:** Backup/sync consuming too much bandwidth, affecting user experience.

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Adjust bandwidth limits (in Mbps)
   BACKUP_BANDWIDTH_LIMIT_MBPS=50         # Was: 100
   DATA_SYNC_BANDWIDTH_LIMIT_MBPS=30      # Was: 100
   ```

2. **Re-run affected setup scripts**
   ```bash
   sudo ./scripts/09-setup-backups.sh
   sudo ./scripts/10-setup-data-pipeline.sh
   ```

3. **Test bandwidth usage**
   ```bash
   # During backup
   iftop -i eth0
   # Should show limited bandwidth to backup destination
   ```

4. **Adjust rclone transfer limits**
   ```bash
   sudo nano /opt/scripts/backup/run-restic-backup.sh

   # Add to rclone commands:
   --bwlimit 10M  # 10 MB/s
   ```

5. **QoS traffic shaping** (advanced)
   ```bash
   # Install tc (traffic control)
   sudo apt install -y iproute2

   # Limit upload bandwidth to 50Mbps on eth0
   sudo tc qdisc add dev eth0 root tbf rate 50mbit burst 32kbit latency 400ms

   # Remove limit
   sudo tc qdisc del dev eth0 root
   ```

**Time estimate:** 10 minutes

---