#!/bin/sh
set -e

export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
export GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
export GOOGLE_REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"
export GOOGLE_ACCESS_TOKEN=""
export VIBER_BOT_TOKEN="${VIBER_BOT_TOKEN:-}"

if [ -n "$GITHUB_TOKEN" ]; then
    GITHUB_TOKEN_BASE64=$(echo -n "x-access-token:${GITHUB_TOKEN}" | base64 | tr -d '\n')
    export GITHUB_TOKEN_BASE64
else
    export GITHUB_TOKEN_BASE64=""
fi

# Google OAuth2 token refresh function
refresh_google_token() {
    if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ] || [ -z "$GOOGLE_REFRESH_TOKEN" ]; then
        return 1
    fi
    RESPONSE=$(curl -s -X POST https://oauth2.googleapis.com/token \
        -d "client_id=${GOOGLE_CLIENT_ID}" \
        -d "client_secret=${GOOGLE_CLIENT_SECRET}" \
        -d "refresh_token=${GOOGLE_REFRESH_TOKEN}" \
        -d "grant_type=refresh_token")
    NEW_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty')
    if [ -n "$NEW_TOKEN" ]; then
        export GOOGLE_ACCESS_TOKEN="$NEW_TOKEN"
        return 0
    else
        echo "  [WARN] Google token refresh failed: $(echo "$RESPONSE" | jq -r '.error_description // .error // "unknown"')"
        return 1
    fi
}

# Refresh Google token at startup
if [ -n "$GOOGLE_REFRESH_TOKEN" ]; then
    echo "  Refreshing Google OAuth2 access token..."
    refresh_google_token && echo "  [OK] Google access token obtained"
fi

ENVSUBST_VARS='${TELEGRAM_BOT_TOKEN} ${BRAVE_API_KEY} ${GITHUB_TOKEN} ${GITHUB_TOKEN_BASE64} ${GOOGLE_ACCESS_TOKEN} ${VIBER_BOT_TOKEN}'

envsubst "$ENVSUBST_VARS" \
    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "=== OpenClaw API Proxy ==="
[ -n "$TELEGRAM_BOT_TOKEN" ] && echo "  + Telegram (8081)" || echo "  - Telegram (no token)"
[ -n "$BRAVE_API_KEY" ] && echo "  + Brave Search (8082)" || echo "  - Brave Search (no key)"
[ -n "$GITHUB_TOKEN" ] && echo "  + GitHub API (8083)" || echo "  - GitHub API (no token)"
[ -n "$GITHUB_TOKEN" ] && echo "  + GitHub Git (8084)" || echo "  - GitHub Git (no token)"
[ -n "$GOOGLE_ACCESS_TOKEN" ] && echo "  + Google API (8085)" || echo "  - Google API (no credentials)"
[ -n "$VIBER_BOT_TOKEN" ] && echo "  + Viber (8086)" || echo "  - Viber (no token)"
echo "  LLM API: use security-llm-proxy:8080"

# Background Google token refresh loop (tokens expire after 60 min)
if [ -n "$GOOGLE_REFRESH_TOKEN" ]; then
    (
        while true; do
            sleep 2700  # 45 min
            echo "[$(date)] Refreshing Google OAuth2 token..."
            if refresh_google_token; then
                envsubst "$ENVSUBST_VARS" \
                    < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
                nginx -s reload
                echo "[$(date)] Google token refreshed, nginx reloaded"
            fi
        done
    ) &
fi

exec nginx -g "daemon off;"
