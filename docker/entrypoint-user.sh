#!/bin/bash
set -euo pipefail

# ML Training Server - User Container Entrypoint
# Makes container behave like a full VM

echo "=== Starting ML Training Workspace ==="

# Get user info from environment
USER_NAME="${USER_NAME:-user}"
USER_UID="${USER_UID:-1000}"
USER_GID="${USER_GID:-1000}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
USER_GROUPS="${USER_GROUPS:-sudo docker}"

wait_for_shared_mount() {
    local target="${SHARED:-/shared}"
    local timeout="${SHARED_MOUNT_TIMEOUT:-60}"
    echo "Checking ${target} availability..."
    for ((i = 1; i <= timeout; i++)); do
        if mountpoint -q "${target}" && timeout 5 ls "${target}" >/dev/null 2>&1; then
            echo "✓ ${target} is accessible (ready after ${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: ${target} is not mounted or readable after ${timeout}s"
    echo "Ensure the host gdrive-shared.service is healthy before restarting this container."
    exit 1
}

# Validate username format
if [[ ! "${USER_NAME}" =~ ^[a-z][-a-z0-9]*$ ]]; then
    echo "ERROR: Invalid username '${USER_NAME}'. Must start with lowercase letter and contain only lowercase letters, digits, and hyphens"
    exit 1
fi

# Validate UID/GID ranges
if [[ ${USER_UID} -lt 1000 ]] || [[ ${USER_UID} -gt 60000 ]]; then
    echo "ERROR: Invalid UID '${USER_UID}'. Must be 1000-60000"
    exit 1
fi

if [[ ${USER_GID} -lt 1000 ]] || [[ ${USER_GID} -gt 60000 ]]; then
    echo "ERROR: Invalid GID '${USER_GID}'. Must be 1000-60000"
    exit 1
fi

echo "Checking GPU availability..."
REQUIRE_GPU="${REQUIRE_GPU:-false}"

if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi &> /dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
        GPU_MEMORY=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
        echo "✓ GPU detected: ${GPU_NAME} (${GPU_MEMORY}MB)"
    else
        echo "⚠️  WARNING: nvidia-smi found but GPU not accessible"
        echo "   Ensure nvidia-container-toolkit is configured and container is started with GPU access."
        if [[ "${REQUIRE_GPU}" == "true" ]]; then
            echo "ERROR: REQUIRE_GPU=true but GPU is not accessible"
            exit 1
        else
            echo "   Continuing without GPU (set REQUIRE_GPU=true to enforce availability)."
        fi
    fi
else
    echo "⚠️  WARNING: nvidia-smi not found inside container"
    if [[ "${REQUIRE_GPU}" == "true" ]]; then
        echo "ERROR: REQUIRE_GPU=true but nvidia-smi is unavailable"
        exit 1
    fi
fi
echo ""

wait_for_shared_mount


echo "Initializing user: ${USER_NAME} (UID: ${USER_UID}, GID: ${USER_GID})"

# Create user and group if they don't exist
if ! getent group "${USER_GID}" > /dev/null 2>&1; then
    groupadd -g "${USER_GID}" "${USER_NAME}"
fi

if ! id -u "${USER_NAME}" > /dev/null 2>&1; then
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USER_NAME}"
    echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
fi

# Ensure supplementary groups are applied
read -r -a USER_GROUP_LIST <<< "${USER_GROUPS}"
VALID_GROUPS=()
for GROUP in "${USER_GROUP_LIST[@]}"; do
    [[ -z "${GROUP}" ]] && continue
    if getent group "${GROUP}" > /dev/null 2>&1; then
        VALID_GROUPS+=("${GROUP}")
    else
        echo "WARNING: Supplementary group '${GROUP}' does not exist inside the container; skipping"
    fi
done

if [[ ${#VALID_GROUPS[@]} -gt 0 ]]; then
    GROUP_CSV=$(IFS=,; echo "${VALID_GROUPS[*]}")
    usermod -aG "${GROUP_CSV}" "${USER_NAME}"
    echo "Added ${USER_NAME} to supplementary groups: ${VALID_GROUPS[*]}"
else
    echo "No supplementary groups assigned to ${USER_NAME}"
fi

# Setup home directory structure
echo "Setting up home directory..."
su - "${USER_NAME}" << 'EOF'
mkdir -p ~/workspace
mkdir -p ~/projects
mkdir -p ~/data
mkdir -p ~/models
mkdir -p ~/notebooks
mkdir -p ~/.config
mkdir -p ~/.ssh
mkdir -p ~/.local/share
mkdir -p ~/.cache

# Create convenient symlinks
ln -sf /workspace ~/workspace-shared
ln -sf /shared ~/shared-data
EOF

# Configure VNC server for user
echo "Configuring VNC server..."
su - "${USER_NAME}" << EOF
mkdir -p ~/.vnc

# Create VNC password file using SHA256 format (matches USER_PASSWORD)
VNC_PASSWORD="${USER_PASSWORD}"
vncpasswd -type=sha256 -f <<<"\${VNC_PASSWORD}" > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create VNC startup script
cat > ~/.vnc/xstartup << 'VNCSTART'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startplasma-x11
VNCSTART
chmod +x ~/.vnc/xstartup

# VNC config
cat > ~/.vnc/config << 'VNCCONF'
geometry=1920x1080
depth=24
dpi=96
VNCCONF
EOF

# Configure XRDP for user
echo "Configuring XRDP server..."
# XRDP uses PAM authentication (system passwords)
# Configure session
cat > /etc/xrdp/startwm.sh << 'XRDPSTART'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startplasma-x11
XRDPSTART
chmod +x /etc/xrdp/startwm.sh

# Configure code-server
echo "Configuring code-server..."
su - "${USER_NAME}" << EOF
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml << CODECONF
bind-addr: 0.0.0.0:8080
auth: password
password: ${CODE_SERVER_PASSWORD:-changeme}
cert: false
CODECONF
EOF

# Configure Jupyter
echo "Configuring Jupyter..."

# Generate Jupyter password hash
JUPYTER_PASSWORD_HASH=$(
    USER_PASSWORD="${USER_PASSWORD}" python3 - <<'PY'
import os
import sys
from jupyter_server.auth import passwd

password = os.environ.get("USER_PASSWORD")
if password is None:
    sys.exit("USER_PASSWORD environment variable is not set")

print(passwd(password))
PY
)

su - "${USER_NAME}" << EOF
mkdir -p ~/.jupyter

cat > ~/.jupyter/jupyter_lab_config.py << JUPCONF
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = False
c.ServerApp.token = ''
c.ServerApp.password = '${JUPYTER_PASSWORD_HASH}'
c.ServerApp.allow_origin = '*'
c.ServerApp.tornado_settings = {'headers': {'Content-Security-Policy': "frame-ancestors 'self' *"}}

# Notebook directory
c.ServerApp.root_dir = '/home/${USER_NAME}/notebooks'

# Extensions
c.ServerApp.jpserver_extensions = {
    'jupyterlab': True,
    'jupyterlab_git': True,
}
JUPCONF
EOF

# Provision Rust toolchain for user
echo "Provisioning Rust toolchain for user..."
if [[ ! -x "/home/${USER_NAME}/.cargo/bin/cargo" ]]; then
    mkdir -p "/home/${USER_NAME}/.cargo"
    rsync -a --chown="${USER_NAME}:${USER_NAME}" /opt/rust/cargo/ "/home/${USER_NAME}/.cargo/"
fi
if [[ ! -d "/home/${USER_NAME}/.rustup/toolchains" ]]; then
    mkdir -p "/home/${USER_NAME}/.rustup"
    rsync -a --chown="${USER_NAME}:${USER_NAME}" /opt/rust/rustup/ "/home/${USER_NAME}/.rustup/"
fi

# Setup shell environment
echo "Configuring shell environment..."
su - ${USER_NAME} << EOF
# Source shared cache environment
[[ -f /opt/cache-env.sh ]] && source /opt/cache-env.sh

# Bash configuration
cat >> ~/.bashrc << 'BASHRC'

# ML Training Server Environment
# Source shared cache environment
[[ -f /opt/cache-env.sh ]] && source /opt/cache-env.sh

export WORKSPACE=/workspace
export SHARED=/shared
export MODELS=~/models
export DATA=~/data

# CUDA
export CUDA_HOME=/usr/local/cuda
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH

# Go
export GOPATH=~/go
export PATH=\$PATH:/usr/local/go/bin:\$GOPATH/bin

# Rust
export PATH="$HOME/.cargo/bin:$PATH"

# Python
export PYTHONPATH=\$WORKSPACE:\$PYTHONPATH

# Helpful aliases
alias jlab='jupyter lab --no-browser --ip=0.0.0.0'
alias jnb='jupyter notebook --no-browser --ip=0.0.0.0'
alias tb='tensorboard --logdir=/shared/tensorboard/${USER_NAME} --bind_all'
alias gpu='watch -n 1 nvidia-smi'
alias ws='cd /workspace'

# Git config
git config --global user.email "${USER_NAME}@ml-train-server"
git config --global user.name "${USER_NAME}"

# Prompt
export PS1='\[\033[01;32m\]\u@ml-workspace\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
BASHRC

# ZSH configuration (if using zsh)
if [ -f ~/.zshrc ]; then
    cat >> ~/.zshrc << 'ZSHRC'

# ML Training Server Environment (same as bash)
export WORKSPACE=/workspace
export SHARED=/shared
[[ -f ~/.bashrc ]] && source ~/.bashrc
ZSHRC
fi
EOF

# Setup systemd-like service management
echo "Configuring services..."
cat > /etc/supervisor/conf.d/user-services.conf << SUPCONF
[supervisord]
nodaemon=true
user=root

[program:sshd]
command=/usr/sbin/sshd -D
autostart=true
autorestart=true
startsecs=5
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
exitcodes=0

[program:vncserver]
command=/bin/bash -c 'su - ${USER_NAME} -c "vncserver :0 -fg -localhost no -PasswordFile ~/.vnc/passwd -SecurityTypes TLSVnc,VNC"'
autostart=true
autorestart=true
startsecs=10
startretries=3
user=${USER_NAME}
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=10
exitcodes=0

[program:xrdp]
command=/usr/sbin/xrdp --nodaemon
autostart=true
autorestart=true
startsecs=10
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=10
exitcodes=0

[program:xrdp-sesman]
command=/usr/sbin/xrdp-sesman --nodaemon
autostart=true
autorestart=true
startsecs=10
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=9
exitcodes=0

[program:novnc]
command=/bin/bash -c 'websockify --web /usr/share/novnc 6080 localhost:5900'
autostart=true
autorestart=true
startsecs=5
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
exitcodes=0

[program:code-server]
command=/bin/bash -c 'su - ${USER_NAME} -c "code-server --bind-addr 0.0.0.0:8080"'
autostart=true
autorestart=true
startsecs=10
startretries=3
user=${USER_NAME}
directory=/home/${USER_NAME}
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
exitcodes=0

[program:jupyter]
command=/bin/bash -c 'su - ${USER_NAME} -c "jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root"'
autostart=true
autorestart=true
startsecs=10
startretries=3
user=${USER_NAME}
directory=/home/${USER_NAME}/notebooks
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
exitcodes=0

[program:pulseaudio]
command=/bin/bash -c 'su - ${USER_NAME} -c "pulseaudio --exit-idle-time=-1"'
autostart=true
autorestart=true
startsecs=5
startretries=3
user=${USER_NAME}
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
exitcodes=0

[program:docker]
command=/usr/bin/dockerd --data-root=/var/lib/state
autostart=true
autorestart=true
startsecs=10
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=1
exitcodes=0
SUPCONF

# Create main supervisord.conf
cat > /etc/supervisor/supervisord.conf <<'SUPERMAIN'
[unix_http_server]
file=/var/run/supervisor.sock

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
SUPERMAIN

# Fix permissions
mkdir -p "/home/${USER_NAME}"
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}"

# Start DBUS (needed for KDE)
mkdir -p /run/dbus
dbus-daemon --system --fork

# Verify DBUS is running with proper socket check (increased timeout for slow systems)
echo "Waiting for DBUS socket..."
DBUS_SOCKET="/var/run/dbus/system_bus_socket"
MAX_ATTEMPTS=60  # Increased from 30 to 60 seconds for slower systems
SLEEP_TIME=1
RETRY_COUNT=3

for attempt in $(seq 1 ${RETRY_COUNT}); do
    echo "  Attempt ${attempt}/${RETRY_COUNT}..."

    for i in $(seq 1 ${MAX_ATTEMPTS}); do
        if [[ -S "${DBUS_SOCKET}" ]]; then
            echo "DBUS started successfully (socket ready after ${i} seconds, attempt ${attempt})"
            break 2
        fi

        # Check if DBUS process is still running
        if [[ $i -eq 10 ]] || [[ $i -eq 30 ]]; then
            if ! pgrep -x dbus-daemon > /dev/null; then
                echo "  WARNING: DBUS daemon process not found, attempting restart..."
                dbus-daemon --system --fork || true
            fi
        fi

        sleep ${SLEEP_TIME}
    done

    # If we reached max attempts, try restarting DBUS
    if [[ $attempt -lt ${RETRY_COUNT} ]]; then
        echo "  Timeout reached, restarting DBUS (attempt ${attempt}/${RETRY_COUNT})..."
        pkill -x dbus-daemon || true
        sleep 2
        dbus-daemon --system --fork
        sleep 2
    fi
done

# Final check after all retries
if [[ ! -S "${DBUS_SOCKET}" ]]; then
    echo "ERROR: DBUS socket not available after ${RETRY_COUNT} retry attempts"
    echo "DBUS daemon may have failed to start"
    echo ""
    echo "Diagnostics:"
    echo "  Socket path: ${DBUS_SOCKET}"
    echo "  Process check:"
    ps aux | grep dbus || true
    echo ""
    echo "  Directory contents:"
    ls -la /var/run/dbus/ || true
    echo ""
    echo "Container may need to be restarted to fix DBUS initialization"
    exit 1
fi

# Print access information
echo ""
echo "=== ML Training Workspace Ready ==="
echo "User: ${USER_NAME}"
echo ""
echo "Access Methods:"
echo "  SSH:          ssh ${USER_NAME}@<server> -p <mapped-port>"
echo "  Guacamole:    http://<server>/guacamole (browser-based, primary)"
echo "  Kasm:         http://<server>/kasm (alternative browser access)"
echo "  VNC Direct:   <server>:<vnc-port> (use VNC client)"
echo "  RDP Direct:   <server>:<rdp-port> (use RDP client)"
echo "  noVNC:        http://<server>:<novnc-port> (HTML5 VNC)"
echo "  VS Code:      http://<server>:<code-port>"
echo "  Jupyter:      http://<server>:<jupyter-port>"
echo "  Desktop:      Via Guacamole/Kasm web interface (recommended)"
echo ""
echo "Volumes:"
echo "  Home:       /home/${USER_NAME}"
echo "  Workspace:  /workspace"
echo "  Shared:     /shared"
echo ""
echo "GPU Access: nvidia-smi to check"
echo ""

# Execute the main command
exec "$@"
