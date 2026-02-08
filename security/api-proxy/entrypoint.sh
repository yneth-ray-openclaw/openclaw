#!/bin/sh
set -e

export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [ -n "$GITHUB_TOKEN" ]; then
    GITHUB_TOKEN_BASE64=$(echo -n "x-access-token:${GITHUB_TOKEN}" | base64 | tr -d '\n')
    export GITHUB_TOKEN_BASE64
else
    export GITHUB_TOKEN_BASE64=""
fi

envsubst '${TELEGRAM_BOT_TOKEN} ${BRAVE_API_KEY} ${GITHUB_TOKEN} ${GITHUB_TOKEN_BASE64}' \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "=== OpenClaw API Proxy ==="
[ -n "$TELEGRAM_BOT_TOKEN" ] && echo "  + Telegram (8081)" || echo "  - Telegram (no token)"
[ -n "$BRAVE_API_KEY" ] && echo "  + Brave Search (8082)" || echo "  - Brave Search (no key)"
[ -n "$GITHUB_TOKEN" ] && echo "  + GitHub API (8083)" || echo "  - GitHub API (no token)"
[ -n "$GITHUB_TOKEN" ] && echo "  + GitHub Git (8084)" || echo "  - GitHub Git (no token)"
echo "  LLM API: use security-llm-proxy:8080"
exec nginx -g "daemon off;"
