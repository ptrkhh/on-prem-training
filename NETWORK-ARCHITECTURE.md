# Network Architecture: Cloudflare Tunnel + Traefik + Local Network

## Overview

The ML Training Server uses a hybrid network architecture that provides:
1. **Remote Access**: Via Cloudflare Tunnel (secure, no port forwarding)
2. **Local Access**: Direct connection when on the same network (fast, no internet roundtrip)
3. **Single URL**: Same URLs work both remotely and locally

## Architecture Diagram

```
Internet Users                    Office Users
     |                                 |
     | HTTPS                           | HTTP/HTTPS
     v                                 v
Cloudflare Edge ──────────────┬──> Local DNS/Hosts
     |                        │         |
     | Cloudflare Tunnel      │         | Direct
     | (encrypted)            │         v
     v                        └──> [Server IP:80]
[Server: cloudflared] ──────────────────┘
     |
     v
[Traefik :80] ───> Routes by hostname
     |
     ├──> remote.domain.com      -> Guacamole (X2Go web interface)
     ├──> health.domain.com      -> Netdata
     ├──> metrics.domain.com     -> Grafana
     ├──> alice-code.domain.com  -> Alice's VS Code
     ├──> jupyter-alice.domain.com -> Alice's Jupyter
     └──> ... (all other services)
```

## How It Works

### For Remote Users (Internet)

1. User visits `remote.yourdomain.com`
2. DNS resolves to Cloudflare's edge network
3. Cloudflare routes request through Cloudflare Tunnel to `cloudflared` daemon on server
4. `cloudflared` forwards to Traefik on `localhost:80`
5. Traefik routes based on hostname to appropriate container
6. Response follows same path back

**Benefits:**
- No ports exposed to internet
- DDoS protection by Cloudflare
- Automatic HTTPS (Cloudflare handles TLS)
- Access control via Cloudflare Access (Google Workspace SSO + 2FA)

### For Local Users (Office Network)

1. User visits `remote.yourdomain.com`
2. Local DNS or `/etc/hosts` resolves to server's local IP (e.g., `192.168.1.100`)
3. Request goes directly to Traefik on `SERVER_IP:80`
4. Traefik routes based on hostname to appropriate container
5. Response comes back directly (no internet)

**Benefits:**
- Full LAN speed (1 Gbps typically)
- No internet bandwidth used
- Lower latency (< 1ms vs 20-100ms via Cloudflare)
- Works even if internet is down

## Configuration

### 1. Cloudflare Tunnel Setup

Run the setup script:
```bash
sudo ./scripts/04-setup-cloudflare-tunnel.sh
```

This script will:
1. Install `cloudflared`
2. Authenticate with Cloudflare
3. Create a tunnel
4. Configure DNS records for all services (*.yourdomain.com -> tunnel)
5. Set up systemd service for automatic startup

The tunnel configuration routes **all** traffic to `localhost:80` (Traefik), which then routes by hostname.

### 2. Traefik Configuration

Traefik is configured to:
- Listen on port 80 (HTTP)
- Route based on `Host()` header
- Use Docker labels to auto-discover services
- Support both Cloudflare Tunnel and direct connections

All services have Traefik labels like:
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.servicename.rule=Host(`subdomain.yourdomain.com`)"
  - "traefik.http.routers.servicename.entrypoints=web"
  - "traefik.http.services.servicename.loadbalancer.server.port=8080"
```

### 3. Local Network Setup

#### Option A: Local DNS (Recommended for multiple users)

If you have a local DNS server (router or dedicated):
```
Add wildcard A record: *.yourdomain.com -> 192.168.1.100
```

Now all users on the network automatically use local connection.

#### Option B: /etc/hosts File

On each local machine, edit `/etc/hosts`:
```
192.168.1.100 remote.yourdomain.com
192.168.1.100 health.yourdomain.com
192.168.1.100 metrics.yourdomain.com
192.168.1.100 alice-code.yourdomain.com
192.168.1.100 jupyter-alice.yourdomain.com
# ... add all subdomains
```

On Windows: `C:\Windows\System32\drivers\etc\hosts`

#### Option C: Browser Extension (Easy per-user)

Use a browser extension like "Redirector" or "Host Switch Plus" to redirect all `*.yourdomain.com` to server IP.

## Service URLs

### Infrastructure Services

| Service | URL | Purpose |
|---------|-----|---------|
| Guacamole | `http://remote.yourdomain.com` | Browser-based remote desktop (X2Go) |
| Netdata | `http://health.yourdomain.com` | Real-time system monitoring |
| Grafana | `http://metrics.yourdomain.com` | Metrics dashboards |
| Prometheus | `http://metrics-backend.yourdomain.com` | Metrics backend (internal) |
| Shared TensorBoard | `http://tensorboard.yourdomain.com` | View all training logs |
| FileBrowser | `http://files.yourdomain.com` | File management |
| Dozzle | `http://logs.yourdomain.com` | Container logs |
| Portainer | `http://portainer.yourdomain.com` | Container management |

### Per-User Services

For each user (e.g., Alice):

| Service | URL | Purpose |
|---------|-----|---------|
| VS Code | `http://alice-code.yourdomain.com` | VS Code in browser |
| Jupyter | `http://jupyter-alice.yourdomain.com` | Jupyter Lab |
| TensorBoard | `http://tensorboard-alice.yourdomain.com` | User's training logs |

### Direct SSH Access (Always Local Ports)

SSH doesn't use Traefik, uses direct port mapping:

| User | SSH Command |
|------|-------------|
| Alice | `ssh alice@server_ip -p 2222` |
| Bob | `ssh bob@server_ip -p 2223` |
| Charlie | `ssh charlie@server_ip -p 2224` |

X2Go client connects via SSH, so use these same ports.

## Security

### Cloudflare Access (Optional but Recommended)

Add authentication to sensitive services:

1. Go to Cloudflare Zero Trust dashboard
2. Create an Access Policy
3. Require Google Workspace login + 2FA
4. Apply to specific subdomains (e.g., `portainer.yourdomain.com`)

This adds SSO authentication before users reach Traefik.

### Firewall Rules

The firewall (UFW) is configured to:
- **Deny all incoming** from internet
- **Allow outgoing** (for Cloudflare Tunnel)
- **Allow from local network** (if configured)

```bash
# Example: Allow local network
sudo ufw allow from 192.168.1.0/24 to any port 80
sudo ufw allow from 192.168.1.0/24 to any port 2222:2230/tcp
```

This allows local users to connect directly while blocking external connections.

## Automatic Local Network Detection

**Cloudflare Tunnel automatically knows when users are local!**

When both Cloudflare DNS and local DNS/hosts point to correct destinations:
- **Remote users**: Cloudflare DNS -> Cloudflare Edge -> Tunnel -> Server
- **Local users**: Local DNS -> Server directly (never touches internet)

No configuration needed on client side if using local DNS server.

## Troubleshooting

### Remote Access Not Working

```bash
# Check Cloudflare Tunnel status
sudo systemctl status cloudflared

# Check tunnel logs
sudo journalctl -u cloudflared -f

# Test Traefik locally
curl -H "Host: remote.yourdomain.com" http://localhost

# Verify DNS
dig remote.yourdomain.com  # Should show Cloudflare IPs
```

### Local Access Not Working

```bash
# Test direct connection
curl -H "Host: remote.yourdomain.com" http://SERVER_IP

# Check /etc/hosts
cat /etc/hosts | grep yourdomain

# Check local DNS
nslookup remote.yourdomain.com
```

### Service Not Routing

```bash
# Check Traefik dashboard
http://SERVER_IP:8080

# Check container labels
docker inspect workspace-alice | grep traefik

# Check Traefik logs
docker logs traefik
```

## Performance Comparison

| Access Method | Latency | Bandwidth | Use Case |
|---------------|---------|-----------|----------|
| Local Direct | < 1ms | 1 Gbps | Office users, best performance |
| Cloudflare Tunnel | 20-100ms | 100-300 Mbps | Remote users, secure access |
| SSH Direct | < 1ms | 1 Gbps | Terminal, X2Go, best for desktop |

## Best Practices

1. **Office users**: Set up local DNS wildcard or `/etc/hosts` for best performance
2. **Remote users**: Use Cloudflare Tunnel + Cloudflare Access for security
3. **SSH/X2Go**: Always use direct SSH ports (2222-2230), not via Cloudflare
4. **Large file transfers**: Use local network when possible
5. **Training jobs**: SSH in and run directly (best performance)
6. **Monitoring dashboards**: Fine via Cloudflare Tunnel

## Summary

This hybrid architecture provides:
- ✅ **Zero exposed ports** to internet (Cloudflare Tunnel handles ingress)
- ✅ **Automatic local network optimization** (direct connection when available)
- ✅ **Single set of URLs** (same URLs work remotely and locally)
- ✅ **Centralized routing** (Traefik handles all HTTP routing)
- ✅ **Security** (Cloudflare Access for SSO + 2FA)
- ✅ **High performance** (local users get full LAN speed)
- ✅ **Reliability** (local access works even if internet is down)

Best of both worlds: secure remote access + fast local access!
