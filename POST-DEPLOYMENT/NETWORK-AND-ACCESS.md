# Network and Access Management

**Documentation**: [README](../README.md) > [Setup Guide](../SETUP-GUIDE.md) > [Operations](./README.md) > Network & Access

---

## Network and Access

### Changing Domain Name

**When:** Rebranding, migration, or organization change.

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Change domain
   DOMAIN="newdomain.com"  # Was: olddomain.com
   ```

2. **Regenerate docker-compose.yml**
   ```bash
   cd ~/train-server/docker
   ./generate-compose.sh
   ```

3. **Update Cloudflare Tunnel**
   ```bash
   sudo /opt/scripts/cloudflare/update-tunnel-config.sh
   # Or manually edit tunnel config
   sudo nano /etc/cloudflared/config.yml
   ```

4. **Restart Cloudflare Tunnel**
   ```bash
   sudo systemctl restart cloudflared
   sudo systemctl status cloudflared
   ```

5. **Restart Traefik**
   ```bash
   cd ~/train-server/docker
   docker compose restart traefik
   ```

6. **Update DNS records**
   - Add new domain CNAME records pointing to Cloudflare Tunnel
   - Keep old domain active during transition (optional)

7. **Test new URLs**
   ```bash
   curl -I https://alice-code.newdomain.com
   curl -I https://health.newdomain.com
   ```

8. **Notify users**
   - Provide new access URLs
   - Update bookmarks

9. **Decommission old domain** (after transition period)

**Time estimate:** 30 minutes

---

### Reconfiguring Cloudflare Tunnel

**When:** Tunnel token expired, configuration changes, or authentication issues.

**Steps:**

1. **Stop current tunnel**
   ```bash
   sudo systemctl stop cloudflared
   ```

2. **Remove old configuration**
   ```bash
   sudo rm /etc/cloudflared/config.yml
   sudo rm ~/.cloudflared/*.json 2>/dev/null
   ```

3. **Re-authenticate with Cloudflare**
   ```bash
   cloudflared tunnel login
   # Follow browser prompts
   ```

4. **Create new tunnel**
   ```bash
   cloudflared tunnel create ml-train-server
   # Note the tunnel ID
   ```

5. **Create new configuration**
   ```bash
   sudo nano /etc/cloudflared/config.yml
   ```

   Paste:
   ```yaml
   tunnel: <tunnel-id>
   credentials-file: /root/.cloudflared/<tunnel-id>.json

   ingress:
     - hostname: "*.yourdomain.com"
       service: http://localhost:80
     - service: http_status:404
   ```

6. **Route DNS to tunnel**
   ```bash
   cloudflared tunnel route dns ml-train-server "*.yourdomain.com"
   ```

7. **Start and enable service**
   ```bash
   sudo systemctl start cloudflared
   sudo systemctl enable cloudflared
   sudo systemctl status cloudflared
   ```

8. **Test access**
   ```bash
   curl -I https://health.yourdomain.com
   ```

**Time estimate:** 15 minutes

---

### Updating SSL Certificates

**When:** Using custom certificates (not Cloudflare-managed).

**Note:** If using Cloudflare Tunnel, SSL is managed automatically. These steps apply only to custom certificate setups.

**Steps:**

1. **Obtain new certificates**
   ```bash
   # Using Let's Encrypt
   sudo certbot certonly --standalone -d yourdomain.com -d *.yourdomain.com
   ```

2. **Copy certificates to Traefik**
   ```bash
   sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem ~/train-server/docker/certs/
   sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem ~/train-server/docker/certs/
   ```

3. **Update Traefik configuration**
   ```bash
   nano ~/train-server/docker/traefik.yml
   # Add certificate configuration
   ```

4. **Restart Traefik**
   ```bash
   cd ~/train-server/docker
   docker compose restart traefik
   ```

5. **Verify SSL**
   ```bash
   openssl s_client -connect yourdomain.com:443 -servername yourdomain.com
   ```

**Auto-renewal setup:**
```bash
# Add to crontab
sudo crontab -e

# Add line:
0 3 * * * certbot renew --quiet && docker compose -f /home/admin/train-server/docker/docker-compose.yml restart traefik
```

**Time estimate:** 20 minutes

---

### Changing SSH Ports

**When:** Security hardening or port conflict.

**Steps:**

1. **Update per-user SSH ports in generate-compose.sh**
   ```bash
   nano ~/train-server/docker/generate-compose.sh

   # Find SSH port mapping section
   # Change base port (e.g., 2222 -> 3222)
   ```

2. **Regenerate docker-compose.yml**
   ```bash
   cd ~/train-server/docker
   ./generate-compose.sh
   ```

3. **Update firewall rules**
   ```bash
   sudo ufw delete allow 2222
   sudo ufw allow 3222/tcp
   ```

4. **Restart containers**
   ```bash
   docker compose up -d
   ```

5. **Test new port**
   ```bash
   ssh alice@localhost -p 3222
   ```

6. **Notify users of new port**

**Time estimate:** 10 minutes

---

### Adding IP Whitelist

**When:** Restrict access to specific networks or IPs.

**Steps:**

1. **Configure firewall whitelist**
   ```bash
   # Allow only specific IPs for SSH
   sudo ufw delete allow 2222
   sudo ufw allow from 203.0.113.0/24 to any port 2222
   sudo ufw allow from 198.51.100.50 to any port 2222
   ```

2. **Add to Cloudflare Access** (if using Cloudflare Tunnel)
   - Log into Cloudflare Dashboard
   - Go to Zero Trust → Access → Applications
   - Edit application
   - Add IP range policy

3. **Configure fail2ban** (optional, for brute-force protection)
   ```bash
   sudo apt install -y fail2ban

   sudo nano /etc/fail2ban/jail.local
   ```

   Add:
   ```ini
   [sshd]
   enabled = true
   port = 2222
   filter = sshd
   logpath = /var/log/auth.log
   maxretry = 3
   bantime = 3600
   ```

   ```bash
   sudo systemctl restart fail2ban
   ```

4. **Test access from allowed IP**

5. **Verify blocking from disallowed IP**

**Time estimate:** 15 minutes

---