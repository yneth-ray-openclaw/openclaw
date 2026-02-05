# OpenClaw API Proxy
# Nginx-based proxy that injects authentication for external APIs
# Keeps API keys/tokens out of agent environment

FROM nginx:alpine

# Install envsubst (part of gettext)
RUN apk add --no-cache gettext

# Copy configuration
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:8080/health || exit 1

EXPOSE 8080 8081 8082 8083 8084 8085

ENTRYPOINT ["/entrypoint.sh"]
