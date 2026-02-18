FROM alpine:3.20

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    tar \
    xz \
    dcron \
    ca-certificates \
    tzdata

# Create backup directory and user
RUN mkdir -p /backups /var/log && \
    adduser -D -s /bin/bash backup && \
    chown -R backup:backup /backups /var/log

# Copy backup script
COPY backup.sh /usr/local/bin/openclaw-backup
RUN chmod +x /usr/local/bin/openclaw-backup

# Set working directory
WORKDIR /backups

# Default volume for backups
VOLUME ["/backups"]

# Health check
HEALTHCHECK --interval=300s --timeout=10s --start-period=30s --retries=3 \
    CMD ls -la /backups 2>/dev/null | grep -q openclaw-backup && exit 0 || exit 1

# Start cron daemon
CMD ["crond", "-f", "-l", "2"]
