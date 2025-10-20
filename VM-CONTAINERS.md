# VM-Like Container Architecture

## Overview

Each user gets **ONE comprehensive container** that behaves like a full virtual machine with complete desktop environment, development tools, and ML stack. This replaces the original GCE instance experience while leveraging Docker's efficiency.

**This matches the GRAND PLAN requirement**: Replacing GCP GCE instances with on-premise workspaces.

## Architecture Change

### ❌ Old Approach (Multiple Containers Per User)
```
alice:
  ├── code-server-alice  (port 8443)
  ├── jupyter-alice      (port 8888)
  └── (separate containers)

bob:
  ├── code-server-bob    (port 8444)
  ├── jupyter-bob        (port 8889)
  └── (separate containers)
```

**Problems:**
- Fragmented experience
- No desktop environment
- Can't run GUI apps
- Different containers don't share state
- Feels like multiple disconnected services

### ✅ New Approach (One VM-Like Container Per User)
```
workspace-alice (ONE container):
  ├── KDE Plasma Desktop
  ├── SSH Server (port 2222) - for terminal + X2Go transport
  ├── X2Go Server - for remote desktop
  ├── VS Code (via Traefik: alice-code.domain.com)
  ├── Jupyter (via Traefik: jupyter-alice.domain.com)
  ├── TensorBoard (via Traefik: tensorboard-alice.domain.com)
  ├── PyCharm, Firefox, Browsers
  ├── Docker-in-Docker
  ├── Full ML Stack
  └── All system tools

workspace-bob (ONE container):
  ├── (same as above)
  └── Different SSH port (2223), different Traefik routes
```

**Benefits:**
- ✅ Full desktop environment (KDE Plasma)
- ✅ Run any GUI application
- ✅ Familiar VM experience
- ✅ All tools share state
- ✅ Can SSH in and use terminal
- ✅ Can use VNC for graphical access
- ✅ Docker-in-Docker for containerization
- ✅ Persistent /home directory
- ✅ System-like process management

## What's Included in Each Container

### 🖥️ Desktop Environment
- **KDE Plasma** - Full-featured desktop
- **Konsole** - Terminal emulator
- **Dolphin** - File manager
- **Kate** - Text editor
- **Spectacle** - Screenshot tool
- **System Settings** - Configuration panel

### 🔐 Remote Access
- **SSH** - Terminal access and X2Go transport
- **X2Go** - Graphical desktop (X2Go client, best performance, low bandwidth)
- **Guacamole** - Desktop in web browser (via X2Go backend)
  - Access at `http://remote.yourdomain.com`
  - No client installation needed
  - Works from any browser

### 💻 Development Tools
- **VS Code** (code-server) - Browser-based
- **VSCodium** - Desktop version
- **PyCharm Community** - JetBrains IDE
- **Jupyter Lab** - Interactive notebooks
- **Git** + git-lfs - Version control

### 🌐 Browsers & Productivity
- **Firefox** - Web browser
- **Chromium** - Alternative browser
- **LibreOffice** - Office suite (Writer, Calc)
- **Evince** - PDF viewer
- **GIMP** - Image editor
- **Inkscape** - Vector graphics
- **VLC** - Media player

### 🤖 ML/AI Stack
**Deep Learning:**
- PyTorch (with CUDA)
- TensorFlow (with CUDA)
- JAX (with CUDA)
- Transformers (Hugging Face)
- Accelerate

**Data Science:**
- NumPy, Pandas, SciPy
- Scikit-learn
- Matplotlib, Seaborn, Plotly

**Computer Vision:**
- OpenCV
- Pillow
- Albumentations

**NLP:**
- spaCy, NLTK, Gensim

**Experiment Tracking:**
- TensorBoard
- Weights & Biases
- MLflow

### 🗄️ Databases & Tools
- **SQLite** + SQLiteBrowser
- **PostgreSQL** client
- **MySQL** client
- **Redis** tools

### 🐳 Containerization
- **Docker** (Docker-in-Docker)
- **docker-compose**
- Full container management within the workspace

### 📝 Language Runtimes
- **Python 3.11+** (primary)
- **Go 1.22**
- **Rust** (latest stable)
- **Julia 1.10**
- **R** (for statistics)
- **Node.js 20** + npm/yarn/pnpm

### 🔧 System Tools
- **tmux** - Terminal multiplexer
- **screen** - Alternative multiplexer
- **htop** - Process viewer
- **vim/nano** - Text editors
- **git** - Version control
- **wget/curl** - Downloads
- **zip/unzip/7zip** - Compression
- **SSH client** - Remote access
- **rsync** - File synchronization

### 🔊 Audio Support
- **PulseAudio** - Audio server
- **pavucontrol** - Volume control
- Audio works over VNC and RDP

## Port Allocation

Each user gets a **block of 100 ports**:

| User  | Base Port | SSH   | VNC   | noVNC  | VS Code | Jupyter | TensorBoard | RDP   |
|-------|-----------|-------|-------|--------|---------|---------|-------------|-------|
| User 1| 10000     | 10022 | 10000 | 10001  | 10002   | 10003   | 10004       | 10005 |
| User 2| 10100     | 10122 | 10100 | 10101  | 10102   | 10103   | 10104       | 10105 |
| User 3| 10200     | 10222 | 10200 | 10201  | 10202   | 10203   | 10204       | 10205 |
| User 4| 10300     | 10322 | 10300 | 10301  | 10302   | 10303   | 10304       | 10305 |
| User 5| 10400     | 10422 | 10400 | 10401  | 10402   | 10403   | 10404       | 10405 |

**Formula:** `Base Port = 10000 + (user_index * 100)`

## Access Methods

### 1. SSH (Command Line)
```bash
ssh alice@server -p 10022
```
- Full terminal access
- Run any command
- Start tmux sessions
- Launch Jupyter/VS Code manually

### 2. VNC (Full Desktop - Native Client)
```
VNC Viewer → server:10000
Password: (VNC_ALICE_PASSWORD)
```
- Full KDE Plasma desktop
- Best performance
- All GUI apps work
- Audio support

### 3. noVNC (Desktop in Browser)
```
http://server:10001
```
- No VNC client needed
- Works in any browser
- Full desktop experience
- Slightly slower than native VNC

### 4. VS Code (Browser)
```
http://server:10002
```
- VS Code in browser
- Full extension support
- Integrated terminal
- Git integration

### 5. Jupyter Lab (Browser)
```
http://server:10003
```
- Notebook interface
- IPython kernels
- File browser
- Terminal access

### 6. X2Go (Alternative Desktop)
- Lower bandwidth than VNC
- Better over slow connections
- Seamless windows mode

## Filesystem Layout

Each container has:

```
/home/alice/          # Persistent user home (mounted from /mnt/storage/homes/alice)
  ├── .bashrc         # Shell configuration
  ├── .ssh/           # SSH keys
  ├── .config/        # App configurations
  ├── workspace/      # Symlink to /workspace
  ├── projects/       # User projects
  ├── notebooks/      # Jupyter notebooks
  ├── models/         # Trained models
  └── data/           # User data

/workspace/           # Ephemeral workspace (mounted from /mnt/storage/workspaces/alice)
  └── (fast scratch space)

/shared/              # Shared datasets (mounted from /mnt/storage/shared, read-only)
  ├── datasets/
  └── tensorboard/
      └── alice/      # User's TensorBoard logs (read-write)

/var/lib/state/       # Container state (mounted from /mnt/storage/docker-volumes/alice-state)
  └── (persistent container data)
```

## VM-Like Features

### 1. Persistent /home Directory
- Survives container restarts
- All user files preserved
- SSH keys, configs, history

### 2. Process Management (supervisord)
- Multiple services running simultaneously
- Automatic service restart
- System-like init system

### 3. Privileged Mode
- Full system capabilities
- Can mount filesystems
- Can load kernel modules (if needed)
- Docker-in-Docker support

### 4. Device Access
- Full /dev access
- GPU devices
- FUSE for custom filesystems

### 5. Network Isolation
- Each container has its own network namespace
- Can run servers on any port internally
- Full networking stack

### 6. Resource Limits
- Memory limits (soft and hard)
- Swap space
- CPU allocation
- But more flexible than VM

## Usage Examples

### Example 1: SSH and Launch Jupyter
```bash
# SSH into container
ssh alice@server -p 10022

# Inside container
cd ~/notebooks
jupyter lab  # Already running on port 8888
# Or manually: jupyter lab --ip=0.0.0.0 --port=8888
```

### Example 2: VNC Desktop Workflow
1. Connect with VNC Viewer to `server:10000`
2. See full KDE desktop
3. Open Konsole terminal
4. Open Firefox for research
5. Open PyCharm for coding
6. Open Dolphin to browse files
7. All windows side-by-side

### Example 3: VS Code + Terminal
1. Open `http://server:10002`
2. Full VS Code interface
3. Use integrated terminal
4. Install extensions
5. Commit to Git

### Example 4: Docker-in-Docker
```bash
# SSH into container
ssh alice@server -p 10022

# Inside container, use Docker
docker run -it ubuntu bash
docker-compose up -d
docker build -t myimage .

# Full Docker access!
```

### Example 5: Train Model in Notebook
1. Open `http://server:10003` (Jupyter)
2. Create new notebook
3. Import PyTorch/TensorFlow
4. Write training code
5. Use GPU automatically
6. Save to ~/models/

## Configuration

### Per-User Environment Variables

In `.env` file or config:
```bash
# Alice's passwords
USER_ALICE_PASSWORD=secure_ssh_password
VNC_ALICE_PASSWORD=secure_vnc_password
CODE_ALICE_PASSWORD=secure_vscode_password

# Bob's passwords
USER_BOB_PASSWORD=bobs_ssh_password
VNC_BOB_PASSWORD=bobs_vnc_password
CODE_BOB_PASSWORD=bobs_vscode_password
```

### Resource Limits

From `config.sh`:
```bash
MEMORY_GUARANTEE_GB=32  # Guaranteed RAM
MEMORY_LIMIT_GB=100     # Max RAM
SWAP_SIZE_GB=50         # Swap space
```

### GPU Sharing

All containers have access to all GPUs. Users coordinate via Slack (as per original plan).

```bash
# Inside container, check GPU
nvidia-smi

# Run training
python train.py  # Automatically uses GPU
```

## Advantages Over Traditional VMs

### Lighter Weight
- Faster startup (seconds vs minutes)
- Less overhead (shared kernel)
- More efficient resource usage

### Better Integration
- Direct access to host GPU
- Efficient volume mounts
- Shared network with monitoring

### Easier Management
- Docker Compose orchestration
- Version-controlled Dockerfiles
- Reproducible environments

### Still VM-Like
- Full desktop environment
- Multiple services
- Persistent storage
- Isolated from other users

## Building and Deploying

### 1. Generate docker-compose.yml
```bash
cd docker
./generate-compose-vm.sh
```

### 2. Build the Image
```bash
docker compose build
```
This builds ONE image used by all user containers.

### 3. Start Services
```bash
docker compose up -d
```

### 4. Check Status
```bash
docker compose ps
docker compose logs workspace-alice
```

### 5. Access
```bash
# SSH
ssh alice@localhost -p 10022

# VNC
vncviewer localhost:10000

# Browser
http://localhost:10001  # noVNC
http://localhost:10002  # VS Code
http://localhost:10003  # Jupyter
```

## Customization Per User

Users can customize their environment:

### Install Additional Software
```bash
# Inside container (as alice)
sudo apt install package-name

# Or with Python
pip install --user some-package

# Persists in /home/alice/.local/
```

### Desktop Customization
- Change wallpaper
- Configure panels
- Install KDE widgets
- Add keyboard shortcuts
- All saved in /home/alice/.config/

### Shell Customization
```bash
# Edit ~/.bashrc or ~/.zshrc
# Install oh-my-zsh
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

## Monitoring

Each container exposes:
- Resource usage (via cAdvisor)
- GPU usage (nvidia-smi exporter)
- Process list (via SSH/VNC)
- Logs (via Dozzle)

View in Grafana:
- Per-container CPU/RAM
- Per-user GPU utilization
- Network I/O
- Disk I/O

## Troubleshooting

### Container Won't Start
```bash
docker compose logs workspace-alice
docker compose restart workspace-alice
```

### VNC Not Working
```bash
# SSH in and check VNC
ssh alice@localhost -p 10022
ps aux | grep vnc
vncserver -list
```

### GPU Not Visible
```bash
# Inside container
nvidia-smi
# If fails, check nvidia runtime is configured
```

### Services Not Starting
```bash
# Inside container
sudo supervisorctl status
sudo supervisorctl restart all
```

## Comparison

| Feature | Traditional VM | Old Docker (Multi-Container) | New VM-Like Container |
|---------|---------------|------------------------------|----------------------|
| Desktop Environment | ✅ Full | ❌ None | ✅ Full KDE |
| Resource Efficiency | ❌ Heavy | ✅ Light | ✅ Light |
| Startup Time | ❌ Minutes | ✅ Seconds | ✅ Seconds |
| GUI Applications | ✅ All | ❌ Limited | ✅ All |
| Multiple Services | ✅ Yes | ⚠️ Separate | ✅ Integrated |
| User Experience | ✅ Familiar | ❌ Fragmented | ✅ Familiar |
| Persistent Storage | ✅ Yes | ⚠️ Volumes | ✅ Yes |
| SSH Access | ✅ Yes | ⚠️ docker exec | ✅ Full SSH |
| Docker-in-Docker | ⚠️ Nested | ❌ No | ✅ Yes |
| Management | ❌ Complex | ✅ Simple | ✅ Simple |

## Best of Both Worlds

This approach combines:
- **VM-like user experience** (desktop, GUI apps, familiar workflow)
- **Docker efficiency** (lightweight, fast startup, easy management)
- **Isolation** (each user has their own environment)
- **Integration** (shared GPU, network, monitoring)

**Result:** Users feel like they have a full VM, but you get Docker's benefits! 🚀
