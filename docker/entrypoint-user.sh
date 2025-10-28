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
VNC_PASSWORD="${VNC_PASSWORD:-vncpass}"

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
echo "${VNC_PASSWORD}" | vncpasswd -f > ~/.vnc/passwd
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
su - ${USER_NAME} << EOF
mkdir -p ~/.jupyter

cat > ~/.jupyter/jupyter_lab_config.py << JUPCONF
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = False
c.ServerApp.token = ''
c.ServerApp.password = ''
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

# Setup shell environment
echo "Configuring shell environment..."
su - ${USER_NAME} << EOF
# Bash configuration
cat >> ~/.bashrc << 'BASHRC'

# ML Training Server Environment
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
export PATH="\$HOME/.cargo/bin:\$PATH"

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
command=/bin/bash -c 'su - ${USER_NAME} -c "vncserver :0 -fg -localhost no -SecurityTypes None"'
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

# Fix permissions
chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME}

# Start DBUS (needed for KDE)
mkdir -p /run/dbus
dbus-daemon --system --fork || true

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
