#!/bin/sh
set -e

# API Proxy Entrypoint
# Substitutes environment variables into nginx config and starts nginx

CONFIG_TEMPLATE="/etc/nginx/nginx.conf.template"
CONFIG_OUTPUT="/etc/nginx/nginx.conf"

echo "=== OpenClaw API Proxy ==="
echo "Configuring nginx..."

# Create base64 encoded GitHub token for git HTTP auth (username:token)
if [ -n "$GITHUB_TOKEN" ]; then
    # GitHub accepts 'x-access-token' as username with token as password
    GITHUB_TOKEN_BASE64=$(echo -n "x-access-token:${GITHUB_TOKEN}" | base64 | tr -d '\n')
    export GITHUB_TOKEN_BASE64
fi

# Set empty defaults for optional variables (nginx will check these)
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GITHUB_TOKEN_BASE64="${GITHUB_TOKEN_BASE64:-}"

# Substitute environment variables in config
envsubst '${ANTHROPIC_API_KEY} ${TELEGRAM_BOT_TOKEN} ${BRAVE_API_KEY} ${GITHUB_TOKEN} ${GITHUB_TOKEN_BASE64}' \
    < "$CONFIG_TEMPLATE" > "$CONFIG_OUTPUT"

# Report which services are configured
echo "Services configured:"
[ -n "$ANTHROPIC_API_KEY" ] && echo "  ✓ Anthropic API (port 8081)" || echo "  ✗ Anthropic API (no key)"
[ -n "$TELEGRAM_BOT_TOKEN" ] && echo "  ✓ Telegram API (port 8082)" || echo "  ✗ Telegram API (no token)"
[ -n "$BRAVE_API_KEY" ] && echo "  ✓ Brave Search (port 8083)" || echo "  ✗ Brave Search (no key)"
[ -n "$GITHUB_TOKEN" ] && echo "  ✓ GitHub API (port 8084)" || echo "  ✗ GitHub API (no token)"
[ -n "$GITHUB_TOKEN" ] && echo "  ✓ GitHub Git (port 8085)" || echo "  ✗ GitHub Git (no token)"
echo ""
echo "Health check: http://localhost:8080/health"
echo "Starting nginx..."

# Start nginx in foreground
exec nginx -g "daemon off;"
