# OpenClaw API Proxy

An nginx-based proxy that handles authentication for external APIs, keeping credentials out of the agent environment.

## Why?

By default, API keys in environment variables are accessible to agent processes. This proxy:

1. **Keeps secrets secure** - API keys only exist in the proxy container
2. **Simplifies agent code** - Agents call `http://api-proxy:8081` instead of managing auth
3. **Centralizes auth** - One place to manage all API credentials
4. **Enables auditing** - Proxy logs show all API calls

## Supported Services

| Port | Service | Upstream |
|------|---------|----------|
| 8080 | Health check | - |
| 8081 | Anthropic API | api.anthropic.com |
| 8082 | Telegram Bot API | api.telegram.org |
| 8083 | Brave Search API | api.search.brave.com |
| 8084 | GitHub API | api.github.com |
| 8085 | GitHub Git (HTTP) | github.com |

## Quick Start

### 1. Add credentials to `.env`

```bash
# .env file (never commit this!)
ANTHROPIC_API_KEY=sk-ant-...
TELEGRAM_BOT_TOKEN=123456:ABC...
BRAVE_API_KEY=BSA...
GITHUB_TOKEN=ghp_...
```

### 2. Start with proxy

```bash
docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d
```

### 3. Verify

```bash
# Check health
curl http://localhost:18780/health

# Test Anthropic (from inside container)
docker exec openclaw-gateway curl -s http://api-proxy:8081/v1/models
```

## Usage from Agents

### Anthropic API

```bash
# Instead of: curl -H "x-api-key: $KEY" https://api.anthropic.com/v1/messages
curl http://api-proxy:8081/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-4", "max_tokens": 100, "messages": [...]}'
```

### Telegram API

```bash
# Instead of: curl https://api.telegram.org/bot$TOKEN/sendMessage
curl "http://api-proxy:8082/bot/sendMessage?chat_id=123&text=Hello"
```

### Brave Search

```bash
# Instead of: curl -H "X-Subscription-Token: $KEY" https://api.search.brave.com/...
curl "http://api-proxy:8083/res/v1/web/search?q=hello"
```

### GitHub API

```bash
# Instead of: curl -H "Authorization: Bearer $TOKEN" https://api.github.com/...
curl http://api-proxy:8084/user
```

### Git Clone/Push via Proxy

```bash
# Configure git to use the proxy for GitHub
git config --global url."http://api-proxy:8085/".insteadOf "https://github.com/"

# Now git operations are authenticated automatically
git clone http://api-proxy:8085/user/repo.git
git push origin main
```

## Configuration

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | No | Anthropic API key (sk-ant-...) |
| `TELEGRAM_BOT_TOKEN` | No | Telegram bot token (123:ABC...) |
| `BRAVE_API_KEY` | No | Brave Search API key |
| `GITHUB_TOKEN` | No | GitHub personal access token |

Services with missing keys will return 503 errors.

### Ports

Default internal ports can be changed by editing `nginx.conf.template`.

The health check port can be exposed differently:

```yaml
# docker-compose.proxy.yml
services:
  api-proxy:
    ports:
      - "9090:8080"  # Health check on port 9090
```

## Security Notes

1. **Never expose proxy ports publicly** - These bypass authentication
2. **Use Docker networks** - Proxy should only be accessible from OpenClaw containers
3. **Rotate credentials regularly** - Update `.env` and restart proxy
4. **Check logs** - `docker logs api-proxy` shows all proxied requests

## Troubleshooting

### "Service not configured" error

The API key for that service is missing. Add it to `.env` and restart:

```bash
docker compose -f docker-compose.yml -f docker-compose.proxy.yml restart api-proxy
```

### Connection refused

Make sure both containers are on the same network:

```bash
docker network inspect openclaw-internal
```

### Git push fails

Ensure your GitHub token has `repo` scope:

```bash
# Test token
curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
```
