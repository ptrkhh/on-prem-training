

## System Package Management

### Adding System Packages

**When:** User requests software that requires system libraries.

**Examples:**
- `ffmpeg` for video processing
- `libopencv-dev` for computer vision
- `postgresql-client` for database access

**Steps:**

1. **Verify package exists**
   ```bash
   docker exec workspace-alice apt-cache search package-name
   ```

2. **Edit Dockerfile**
   ```bash
   cd ~/train-server/docker
   nano Dockerfile.user-workspace

   # Find appropriate section (e.g., DEVELOPMENT TOOLS)
   # Add package to RUN apt-get install line
   RUN apt-get update && apt-get install -y \
       existing-package \
       ffmpeg \
       libopencv-dev \
       && rm -rf /var/lib/apt/lists/*
   ```

3. **Rebuild affected container(s)**
   ```bash
   cd ~/train-server/docker

   # Option A: Single user (faster, less disruption)
   docker compose build workspace-alice
   docker compose up -d workspace-alice

   # Option B: All users (for widely-needed packages)
   docker compose build
   docker compose up -d
   ```

4. **Notify affected users**
   ```
   Subject: Container restart - New package available

   Your workspace container was restarted to install [package-name].
   Please save your work and reconnect via web desktop, Guacamole, or SSH.
   ```

5. **Verify installation**
   ```bash
   docker exec workspace-alice which ffmpeg
   docker exec workspace-alice apt list --installed | grep opencv
   ```

**Time estimate:** 5-10 minutes per request

**Downtime:** 30-60 seconds per container restart

---

### Updating Base Container Image

**When:** New CUDA version, Ubuntu updates, or security patches.

**Steps:**

1. **Review current image**
   ```bash
   cd ~/train-server/docker
   cat Dockerfile.user-workspace | grep FROM
   # Example: FROM nvidia/cuda:12.4.0-devel-ubuntu24.04
   ```

2. **Update base image tag**
   ```bash
   nano Dockerfile.user-workspace

   # Update FROM line
   FROM nvidia/cuda:12.6.0-devel-ubuntu24.04
   ```

3. **Test with single user first**
   ```bash
   docker compose build workspace-alice
   docker compose up -d workspace-alice

   # Verify
   docker exec workspace-alice nvidia-smi
   docker exec workspace-alice python3 -c "import torch; print(torch.cuda.is_available())"
   ```

4. **If successful, rebuild all containers**
   ```bash
   # Schedule during maintenance window
   docker compose build
   docker compose up -d
   ```

5. **Verify all users**
   ```bash
   for user in alice bob charlie dave eve; do
       echo "=== $user ==="
       docker exec workspace-$user nvidia-smi | head -n 5
   done
   ```

6. **Commit changes**
   ```bash
   git add docker/Dockerfile.user-workspace
   git commit -m "Update base image to CUDA 12.6"
   ```

**Time estimate:** 1-2 hours (build time)

**Recommendation:** Test on staging user first, schedule during low-usage hours

---