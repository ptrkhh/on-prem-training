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

# Validate USER_PASSWORD length for VNC (6-8 chars required)
PASS_LEN=${#USER_PASSWORD}
if [[ ${PASS_LEN} -lt 6 ]]; then
    echo "WARNING: USER_PASSWORD is too short for VNC (min 6 chars). Padding to 6 chars."
    USER_PASSWORD="${USER_PASSWORD}000000"
    USER_PASSWORD="${USER_PASSWORD:0:8}"
elif [[ ${PASS_LEN} -gt 8 ]]; then
    echo "INFO: Truncating USER_PASSWORD to 8 chars for VNC compatibility"
    USER_PASSWORD="${USER_PASSWORD:0:8}"
fi

echo "Initializing user: ${USER_NAME} (UID: ${USER_UID}, GID: ${USER_GID})"

# Create user and group if they don't exist
if ! getent group ${USER_GID} > /dev/null 2>&1; then
    groupadd -g ${USER_GID} ${USER_NAME}
fi

if ! id -u ${USER_NAME} > /dev/null 2>&1; then
    useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USER_NAME}
    echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
    usermod -aG sudo,docker ${USER_NAME}
fi

# Setup home directory structure
echo "Setting up home directory..."
su - ${USER_NAME} << 'EOF'
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
su - ${USER_NAME} << EOF
mkdir -p ~/.vnc

# Create VNC password file
echo "${USER_PASSWORD}" | vncpasswd -f > ~/.vnc/passwd
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
su - ${USER_NAME} << EOF
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
JUPYTER_PASSWORD_HASH=$(python3 -c "from jupyter_server.auth import passwd; print(passwd('${USER_PASSWORD}'))")

su - ${USER_NAME} << EOF
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

# Install Rust for user
echo "Installing Rust for user..."
su - ${USER_NAME} << EOF
if [ ! -d ~/.cargo ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
EOF

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
command=/bin/bash -c 'su - ${USER_NAME} -c "vncserver :0 -fg -localhost no -PasswordFile ~/.vnc/passwd -SecurityTypes VncAuth"'
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
command=/usr/bin/dockerd
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
chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME}

# Start DBUS (needed for KDE)
mkdir -p /run/dbus
dbus-daemon --system --fork

# Verify DBUS is running with proper socket check
echo "Waiting for DBUS socket..."
DBUS_SOCKET="/var/run/dbus/system_bus_socket"
for i in {1..10}; do
    if [[ -S "${DBUS_SOCKET}" ]]; then
        echo "DBUS started successfully (socket ready after ${i} attempts)"
        break
    fi
    if [[ $i -eq 10 ]]; then
        echo "ERROR: DBUS socket not available after 10 attempts"
        echo "Check: ls -la /var/run/dbus/"
        ls -la /var/run/dbus/ || true
        exit 1
    fi
    echo "Waiting for DBUS socket... (attempt $i/10)"
    sleep 1
done

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
