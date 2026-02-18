# OpenClaw Backup System

A Docker-based backup solution for OpenClaw's `~/.openclaw` directory with automatic rotation, compression, and Telegram notifications.

## Features

- **Maximum Compression**: Uses `tar.xz` with `--extreme` flag for best compression ratios
- **Auto-Rotation**: Automatically deletes backups older than a configurable number of days
- **Cron Integration**: Runs on a schedule inside a Docker container
- **Telegram Notifications**: Get instant alerts when backups complete or fail
- **Logging**: Detailed logs for troubleshooting and auditing
- **Resource Limits**: Constrained CPU and memory usage to avoid host impact

## Quick Start

### 1. Copy and Configure

```bash
cp backup/.env.example backup/.env
# Edit .env and add your Telegram credentials
nano backup/.env
```

### 2. Build and Start

```bash
cd backup
docker-compose up -d
```

### 3. Verify Setup

```bash
# Check logs
docker-compose logs -f openclaw-backup

# List backups
ls -lh backup/backups/
```

## Configuration

### Environment Variables

- **`TELEGRAM_BOT_TOKEN`**: Your Telegram bot token (from BotFather)
- **`TELEGRAM_CHAT_ID`**: Chat or group ID to send notifications to
- **`RETENTION_DAYS`**: Keep backups for this many days (default: 7)
- **`TZ`**: Timezone for cron scheduling (default: UTC)

### Cron Schedule

Edit `crontab` to customize backup timing:

```cron
# Daily at 2 AM UTC
0 2 * * * /usr/local/bin/openclaw-backup

# Multiple times per day (every 6 hours)
0 */6 * * * /usr/local/bin/openclaw-backup
```

## Getting Telegram Credentials

### Bot Token

1. Open Telegram and search for `@BotFather`
2. Send `/newbot` and follow prompts
3. Copy the token provided

### Chat ID

#### For Direct Messages:
1. Send any message to your bot
2. Run:
   ```bash
   curl https://api.telegram.org/bot{TOKEN}/getUpdates
   ```
3. Find your `chat.id` in the response

#### For Group Messages:
1. Add the bot to your group
2. Send any message mentioning the bot
3. Run the same curl command above
4. Note: Group IDs are negative (e.g., `-1001234567890`)

## Backup Structure

```
backups/
├── openclaw-backup-20240218-020015.tar.xz  (52 MB)
├── openclaw-backup-20240217-020010.tar.xz  (51 MB)
└── openclaw-backup-20240216-020005.tar.xz  (53 MB)
```

## Manual Backup

Run a backup manually without cron:

```bash
docker-compose exec openclaw-backup openclaw-backup
```

## Restore from Backup

```bash
# Extract to a temporary location
tar -xf backups/openclaw-backup-20240218-020015.tar.xz -C /tmp/

# Copy back to home
cp -r /tmp/.openclaw ~/.openclaw.restored
```

## Logs

### Container Logs

```bash
docker-compose logs -f
```

### Backup Logs

```bash
tail -f backup/logs/openclaw-backup.log
```

## Troubleshooting

### Backups not running

```bash
# Check cron is active
docker-compose exec openclaw-backup ps aux | grep crond

# Manually trigger
docker-compose exec openclaw-backup /usr/local/bin/openclaw-backup
```

### Telegram notifications failing

- Verify `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `.env`
- Check container logs for errors
- Ensure bot has permission to send messages to the chat

### Backups taking too long

- Increase resource limits in `docker-compose.yml`
- Reduce `~/.openclaw` size by archiving old sessions
- Run backups during off-peak hours

## Performance Notes

- **Compression Time**: 30-120s depending on source size
- **Compression Ratio**: ~10:1 typical for OpenClaw data
- **Disk Space**: Allocate at least 10x the source directory size

## Security

- Backups are stored locally; use encrypted storage for remote backups
- Bot token in `.env` should be protected (don't commit to version control)
- Consider backing up to external storage (S3, B2, etc.)

## Docker Cleanup

```bash
# Stop and remove
docker-compose down

# Prune unused images
docker image prune -a
```

## Advanced Usage

### Custom Backup Locations

```bash
# In docker-compose.yml environment:
BACKUP_SOURCE: /custom/path
BACKUP_DEST: /custom/backups
```

### Different Retention Policies

```bash
# Keep backups for 30 days
RETENTION_DAYS=30

# Keep backups for 1 day (daily rotation)
RETENTION_DAYS=1
```

### Disable Notifications

Leave `TELEGRAM_BOT_TOKEN` empty in `.env` to skip notifications.

## License

Same as OpenClaw.
