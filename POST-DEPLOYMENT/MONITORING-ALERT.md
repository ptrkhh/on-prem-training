


## Monitoring and Alerts

### Updating Telegram Bot Settings

**When:** Bot token changed, new chat ID, or group migration.

**Steps:**

1. **Get new bot token** (if creating new bot)
   - Open Telegram, search @BotFather
   - Send `/newbot`, follow prompts
   - Copy token

2. **Get chat ID**
   - Start chat with your bot
   - Message @userinfobot or @RawDataBot
   - Copy chat ID

3. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
   TELEGRAM_CHAT_ID="-1001234567890"
   ```

4. **Re-run monitoring setup**
   ```bash
   sudo ./scripts/08-setup-monitoring.sh
   ```

5. **Test alert**
   ```bash
   /opt/scripts/monitoring/send-telegram-alert.sh info "Test alert from ML training server"
   ```

6. **Verify message received in Telegram**

**Time estimate:** 5 minutes

---

### Adding Email Alerts

**When:** Want email notifications in addition to Telegram.

**Steps:**

1. **Install mail utilities**
   ```bash
   sudo apt install -y mailutils postfix
   # Select "Internet Site" during Postfix setup
   ```

2. **Configure Postfix**
   ```bash
   sudo nano /etc/postfix/main.cf

   # Set:
   myhostname = ml-train-server.yourdomain.com
   mydomain = yourdomain.com
   ```

3. **Restart Postfix**
   ```bash
   sudo systemctl restart postfix
   ```

4. **Update monitoring scripts**
   ```bash
   sudo nano /opt/scripts/monitoring/send-telegram-alert.sh

   # Add at end of script:
   echo "$MESSAGE" | mail -s "[$LEVEL] ML Training Server Alert" admin@yourdomain.com
   ```

5. **Test email**
   ```bash
   echo "Test email" | mail -s "Test" admin@yourdomain.com
   ```

**Alternative:** Use external SMTP (Gmail, SendGrid, etc.)
```bash
sudo apt install -y ssmtp

sudo nano /etc/ssmtp/ssmtp.conf

# Add:
root=admin@yourdomain.com
mailhub=smtp.gmail.com:587
AuthUser=your-email@gmail.com
AuthPass=your-app-password
UseSTARTTLS=YES
```

**Time estimate:** 15 minutes

---

### Adjusting Alert Thresholds

**When:** Too many false alerts or want earlier warnings.

**Steps:**

1. **Update configuration**
   ```bash
   nano ~/train-server/config.sh

   # Adjust thresholds
   GPU_TEMP_THRESHOLD=85          # Was: 80
   FS_USAGE_THRESHOLD=85          # Was: 90
   USER_QUOTA_WARNING_PERCENT=75  # Was: 80
   ```

2. **Re-run monitoring setup**
   ```bash
   sudo ./scripts/08-setup-monitoring.sh
   ```

3. **Test new thresholds** (optional)
   ```bash
   # Manually trigger check scripts
   sudo /opt/scripts/monitoring/check-gpu-temp.sh
   sudo /opt/scripts/monitoring/check-disk-usage.sh
   ```

**Time estimate:** 5 minutes

---

### Silencing Alerts Temporarily

**When:** Scheduled maintenance, known issues, or alert fatigue.

**Steps:**

1. **Disable Telegram alerts**
   ```bash
   sudo mv /opt/scripts/monitoring/send-telegram-alert.sh \
     /opt/scripts/monitoring/send-telegram-alert.sh.disabled
   ```

2. **Disable cron jobs**
   ```bash
   sudo crontab -e
   # Comment out monitoring lines:
   # */15 * * * * /opt/scripts/monitoring/check-all.sh
   ```

3. **After maintenance, re-enable**
   ```bash
   sudo mv /opt/scripts/monitoring/send-telegram-alert.sh.disabled \
     /opt/scripts/monitoring/send-telegram-alert.sh

   sudo crontab -e
   # Uncomment monitoring lines
   ```

**Alternative:** Snooze specific alerts only
```bash
# Temporarily increase threshold for specific check
sudo nano /opt/scripts/monitoring/check-disk-usage.sh
# Change threshold in script
```

**Time estimate:** 2 minutes

---