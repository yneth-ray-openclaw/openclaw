# OpenClaw Backup System Integration

This backup system is integrated into the OpenClaw repository under `scripts/backup/`.

## Quick Start from OpenClaw Root

```bash
cd scripts/backup
cp .env.example .env
# Edit .env with your Telegram credentials
./setup.sh
```

## Integration Points

### 1. Docker Setup

The backup system includes its own `docker-compose.yml` configured to:
- Mount the local `~/.openclaw` directory (read-only)
- Store backups in `scripts/backup/backups/`
- Use cron for scheduled execution
- Log to `scripts/backup/logs/`

### 2. Cron Schedule

Edit `scripts/backup/crontab` to customize backup timing. Default:
- **Daily backup**: 2:00 AM UTC
- **Weekly rotation check**: 3:00 AM UTC every Sunday

### 3. Configuration

All settings in `scripts/backup/.env`:
- `TELEGRAM_BOT_TOKEN`: Your bot token
- `TELEGRAM_CHAT_ID`: Destination chat/group
- `RETENTION_DAYS`: How many days to keep backups (default: 7)
- `TZ`: Timezone for cron scheduling

### 4. Backup Location

Backups are stored in: `scripts/backup/backups/openclaw-backup-TIMESTAMP.tar.xz`

Format: `openclaw-backup-YYYYMMDD-HHMMSS.tar.xz`

## Usage

### Start Backup Service

```bash
cd scripts/backup
docker-compose up -d
```

### Manual Backup

```bash
docker-compose exec openclaw-backup /usr/local/bin/openclaw-backup
```

### View Logs

```bash
# Container logs
docker-compose logs -f

# Backup logs
tail -f logs/openclaw-backup.log
```

### List Backups

```bash
ls -lh backups/
```

### Stop Backup Service

```bash
docker-compose down
```

## Restore from Backup

```bash
# Extract to temporary location
tar -xf backups/openclaw-backup-20240218-020015.tar.xz -C /tmp/

# Restore
cp -r /tmp/.openclaw ~/.openclaw.backup-restored
```

## Environment Setup

### Telegram Bot Configuration

1. **Create a bot**:
   - Open Telegram, search `@BotFather`
   - Send `/newbot` and follow prompts
   - Copy the token provided

2. **Get Chat ID**:
   - Send a message to your bot
   - Run: `curl https://api.telegram.org/bot{TOKEN}/getUpdates`
   - Extract `chat.id` from the response
   - For groups, the ID is negative (e.g., `-1001234567890`)

3. **Add to .env**:
   ```bash
   TELEGRAM_BOT_TOKEN=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
   TELEGRAM_CHAT_ID=-1001234567890
   ```

## Troubleshooting

### Backups Not Running

```bash
# Check container status
docker-compose ps

# Check cron daemon
docker-compose exec openclaw-backup ps aux | grep crond

# Manually run backup
docker-compose exec openclaw-backup /usr/local/bin/openclaw-backup
```

### Telegram Notifications Failing

- Verify `TELEGRAM_BOT_TOKEN` is correct
- Verify `TELEGRAM_CHAT_ID` is correct (negative for groups)
- Check container logs: `docker-compose logs`
- Ensure bot has permission to send messages

### Backup Taking Too Long

- Check `~/.openclaw` size: `du -sh ~/.openclaw`
- Increase container resources in `docker-compose.yml`
- Run backups during off-peak hours by editing `crontab`

### Disk Space Issues

- Check available space: `df -h`
- Reduce `RETENTION_DAYS` to keep fewer backups
- Archive old backups to external storage

## Performance

- **Compression time**: 30-120s depending on data size
- **Typical compression ratio**: 10:1
- **Disk overhead**: Allocate 10x the source size for safety

## Security Considerations

- **Local storage**: Backups are stored locally; protect with disk encryption
- **Secrets in .env**: Never commit `.env` to version control
- **Bot token**: Keep your Telegram bot token confidential
- **Network**: Bot uses HTTPS to Telegram API
- **Container**: Runs with limited resources and read-only access to source

## Advanced Configuration

### Custom Backup Paths

Edit `docker-compose.yml` environment:
```yaml
BACKUP_SOURCE: /custom/path
BACKUP_DEST: /custom/backups
```

### Different Retention

```bash
# Keep 30-day backups
RETENTION_DAYS=30

# Daily rotation (1-day retention)
RETENTION_DAYS=1
```

### Disable Notifications

Leave `TELEGRAM_BOT_TOKEN` empty to skip Telegram notifications.

## CI/CD Integration

To run backups in CI/CD pipelines:

```bash
#!/bin/bash
cd scripts/backup
docker-compose run --rm openclaw-backup /usr/local/bin/openclaw-backup
```

## Docker Cleanup

```bash
# Stop service
docker-compose down

# Remove image
docker rmi openclaw-backup:latest

# Prune all unused containers and images
docker system prune -a
```

## Support

- See `README.md` for full documentation
- Check logs: `logs/openclaw-backup.log`
- Review Docker Compose output: `docker-compose logs`

## License

Same as OpenClaw.
