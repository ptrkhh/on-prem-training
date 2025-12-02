# Google Drive Mount Resilience Improvements

## Overview

This document describes the comprehensive resilience improvements made to ensure the rclone FUSE mount (`/mnt/storage/shared`) is always available and automatically recovers from failures.

## Problem

The Google Drive mount is critical infrastructure for this server:
- Docker containers depend on it for shared storage
- Stale/hung mounts cause Docker failures
- Network hiccups can cause mount disconnects
- Manual intervention was required to recover

## Solution

A multi-layered approach to ensure mount availability:

### 1. Aggressive Systemd Restart Policies

**File**: `/etc/systemd/system/gdrive-shared.service`

**Improvements**:
- `Restart=always` - Restart on ANY exit (not just failures)
- `RestartSec=10s` - Fast recovery (reduced from 30s)
- `StartLimitBurst=10` - Allow more restart attempts
- `StartLimitIntervalSec=300` - Within 5 minute window
- Improved `ExecStartPost` - 60 second mount verification

**Why this matters**:
- Network hiccups cause clean exits (exit code 0)
- Previous config (`Restart=on-failure`) wouldn't restart on clean exits
- Now automatically recovers from all disconnections

### 2. Continuous Health Monitoring

**Files**:
- `/etc/systemd/system/gdrive-shared-healthcheck.service`
- `/etc/systemd/system/gdrive-shared-healthcheck.timer`
- `/usr/local/bin/gdrive-healthcheck.sh`

**How it works**:
- Timer runs health check every 60 seconds
- Detects three failure modes:
  1. Mount point doesn't exist
  2. Not mounted (mountpoint check fails)
  3. Stale/hung mount (ls command hangs)
- Automatically restarts service on failure
- Logs to `/var/log/gdrive-healthcheck.log`

**Why this matters**:
- Catches issues the systemd service itself might miss
- Detects stale mounts that appear "running" but are unresponsive
- Provides continuous monitoring independent of the mount service

### 3. Docker Compose Pre-flight Checks

**Changes**:

1. **generate-compose.sh** ([docker/generate-compose.sh:105-141](docker/generate-compose.sh#L105-L141))
   - Added mount validation before generating docker-compose.yml
   - Checks if mount exists, is mounted, and is responsive
   - Fails fast with helpful error messages

2. **docker-compose-with-mount-check wrapper** (optional)
   - File: `/usr/local/bin/docker-compose-with-mount-check`
   - Validates mount before every docker-compose command
   - Auto-starts mount service if needed
   - Can be used as a drop-in replacement for `docker compose`

**Why this matters**:
- Prevents cryptic Docker errors like "file exists" mount failures
- Catches mount issues BEFORE attempting to start containers
- Provides clear, actionable error messages

## Installation

**IMPORTANT**: These resilience features are now **built into the main setup script**!

### For New Installations

Simply run the main setup script:

```bash
sudo /home/p/on-prem-training/scripts/02-setup-gdrive-shared.sh
```

All resilience features will be automatically configured.

### For Existing Installations (Upgrade)

You have two options:

**Option 1: Re-run the main setup script** (recommended)
```bash
sudo /home/p/on-prem-training/scripts/02-setup-gdrive-shared.sh
```
This will update your configuration with all resilience improvements.

**Option 2: Use the standalone upgrade script**
```bash
sudo /home/p/on-prem-training/scripts/improve-mount-resilience.sh
```

Both options will:
1. ✅ Update systemd service with aggressive restart policies
2. ✅ Install health monitoring timer and script
3. ✅ Create docker-compose wrapper script (optional)
4. ✅ Enable and start all services

## Verification

### Check Mount Status
```bash
# Check main service
sudo systemctl status gdrive-shared.service

# Check health monitoring timer
sudo systemctl status gdrive-shared-healthcheck.timer

# View health check logs
sudo tail -f /var/log/gdrive-healthcheck.log
```

### Test Mount Resilience
```bash
# Simulate mount failure (kill rclone process)
sudo pkill -9 rclone

# Watch automatic recovery
sudo journalctl -u gdrive-shared.service -f
```

Within 10-70 seconds, you should see:
1. Systemd detects process exit
2. Waits 10 seconds (RestartSec)
3. Automatically restarts the mount
4. Health check verifies recovery

### Test Docker Integration
```bash
# Generate docker-compose.yml (includes mount check)
cd /home/p/on-prem-training/docker
./generate-compose.sh

# Or use wrapper for additional safety
docker-compose-with-mount-check up -d
```

## Monitoring

### Health Check Logs
```bash
# Real-time monitoring
sudo tail -f /var/log/gdrive-healthcheck.log

# Recent checks
sudo tail -50 /var/log/gdrive-healthcheck.log
```

### Systemd Logs
```bash
# Mount service logs
sudo journalctl -u gdrive-shared.service -n 100

# Health check logs
sudo journalctl -u gdrive-shared-healthcheck.timer -n 50

# Follow in real-time
sudo journalctl -u gdrive-shared.service -f
```

## Recovery Time

| Failure Scenario | Detection | Recovery | Total |
|-----------------|-----------|----------|-------|
| rclone crash | Immediate | 10s | ~10s |
| Network disconnect | Immediate | 10s | ~10s |
| Stale/hung mount | ≤60s | 10s | ~70s |
| Mount point deleted | ≤60s | 10s | ~70s |

## Best Practices

### For Development
1. Always use `./generate-compose.sh` to create docker-compose.yml
   - Includes automatic mount validation
   - Catches issues early

2. Optional: Create alias for docker-compose wrapper
   ```bash
   # Add to ~/.bashrc or ~/.zshrc
   alias docker-compose='docker-compose-with-mount-check'
   ```

### For Production
1. Monitor health check logs regularly
   ```bash
   sudo tail -f /var/log/gdrive-healthcheck.log
   ```

2. Set up alerts for repeated failures
   - If health check restarts service >3 times in 5 minutes
   - Indicates persistent network or Google Drive API issues

3. Check mount performance
   ```bash
   # Test read speed
   time ls -la /mnt/storage/shared | head -20

   # Should complete in <5 seconds
   # If slower, may indicate network issues
   ```

## Troubleshooting

### Mount keeps restarting
```bash
# Check for network issues
ping -c 5 8.8.8.8

# Check Google Drive API status
curl -I https://www.googleapis.com/drive/v3/about

# Check rclone config
sudo rclone lsd gdrive-shared: --max-depth 1
```

### Health check not running
```bash
# Check timer status
sudo systemctl status gdrive-shared-healthcheck.timer

# Enable timer if disabled
sudo systemctl enable gdrive-shared-healthcheck.timer
sudo systemctl start gdrive-shared-healthcheck.timer
```

### Docker still fails with mount errors
```bash
# Verify mount is responsive
timeout 5 ls /mnt/storage/shared

# If hangs or fails, run fix script
sudo /home/p/on-prem-training/scripts/fix-gdrive-mount.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Containers                      │
│  (workspace-alice, workspace-bob, tensorboard, etc.)    │
└────────────────────┬────────────────────────────────────┘
                     │ mount: /mnt/storage/shared:/shared
                     │
┌────────────────────▼────────────────────────────────────┐
│              /mnt/storage/shared                         │
│           (FUSE mount to Google Drive)                   │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┬──────────────┐
        │                         │              │
┌───────▼────────┐    ┌──────────▼─────┐  ┌────▼─────┐
│ systemd        │    │ Health Check   │  │ Docker   │
│ gdrive-shared  │◄───┤ Timer (60s)    │  │ Compose  │
│ service        │    │                │  │ Pre-     │
│                │    │ Detects stale  │  │ flight   │
│ Restart=always │    │ mounts & auto  │  │ Check    │
│ RestartSec=10s │    │ restarts       │  │          │
└────────────────┘    └────────────────┘  └──────────┘
```

## Files Modified

### Created
- [scripts/improve-mount-resilience.sh](scripts/improve-mount-resilience.sh) - Installation script
- `/etc/systemd/system/gdrive-shared-healthcheck.service` - Health check service
- `/etc/systemd/system/gdrive-shared-healthcheck.timer` - Health check timer
- `/usr/local/bin/gdrive-healthcheck.sh` - Health check script
- `/usr/local/bin/docker-compose-with-mount-check` - Docker wrapper (optional)
- This file - Documentation

### Modified
- [docker/generate-compose.sh:105-141](docker/generate-compose.sh#L105-L141) - Added mount validation
- `/etc/systemd/system/gdrive-shared.service` - Improved restart policies (via script)

## Summary

The mount is now **resilient and self-healing**:

✅ Automatically recovers from crashes (10s)
✅ Automatically recovers from network issues (10s)
✅ Detects and fixes stale mounts (60s)
✅ Prevents Docker from starting with broken mounts
✅ Continuous monitoring and logging
✅ No manual intervention needed

**You should never encounter the "Transport endpoint is not connected" error again** during normal operations.
