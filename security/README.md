# OpenClaw Security & Proxy Stack

A Docker-based security monitoring and API proxy overlay for OpenClaw. Provides network IDS, container runtime security, a transparent LLM API proxy with guard hooks, an nginx-based API proxy for external services, and unified Telegram alerting — without modifying any existing OpenClaw files.

## Architecture

```
                         Internet
                            |
                    +-------+-------+
                    |   docker0     |
                    |   bridge      |
                    +---+-------+---+
                        |       |
           +------------+       +------------+
           |                                 |
  +--------+--------+              +--------+--------+
  | openclaw-gateway |              |  openclaw-cli   |
  +---------+-------+              +--------+--------+
            |                               |
            |         openclaw_net          |
            +------+--------+--------------+
                   |        |
     +-------------+--+  +-+----------------+
     | LLM Proxy      |  | API Proxy        |
     | (FastAPI)       |  | (nginx)          |
     | :8080 -> LLM    |  | :8081 Telegram   |
     | guard hooks     |  | :8082 Brave      |
     | streaming       |  | :8083 GitHub API |
     +--------+--------+  | :8084 GitHub Git |
              |            +----+---+---+----+
      Anthropic / OpenAI        |   |   |
                          Telegram Brave GitHub

  +---------------------+    +---------------------+
  | security-suricata   |    | security-tracee     |
  | network_mode: host  |    | privileged, pid:host|
  | monitors docker0    |    | eBPF container mon  |
  +----------+----------+    +----------+----------+
             |                          |
             v                          v
    suricata/logs/eve.json      /tmp/tracee/out
             |                          |
             +----------+---------------+
                        |
               +--------+--------+
               | security-alerter|
               | tail -F logs    |
               | -> Telegram     |
               +-----------------+
```

## Components

| Service | Container | Purpose |
|---------|-----------|---------|
| **LLM Proxy** | `security-llm-proxy` | FastAPI reverse proxy for Anthropic/OpenAI. Hides API key, supports streaming, guard-ready hook point |
| **API Proxy** | `security-api-proxy` | nginx reverse proxy for Telegram, Brave Search, GitHub API, GitHub Git. Injects auth per-service |
| **Suricata** | `security-suricata` | Network IDS — monitors docker0 bridge with ET Open rules |
| **Tracee** | `security-tracee` | Runtime security — eBPF-based container monitoring |
| **Alerter** | `security-alerter` | Aggregates Suricata and Tracee alerts, sends to Telegram |

## Port Reference

| Service | Container Port | Host Port | Access from OpenClaw |
|---------|---------------|-----------|---------------------|
| LLM Proxy | 8080 | 18790 | `http://security-llm-proxy:8080` |
| API Proxy health | 8080 | 18780 | `http://security-api-proxy:8080/health` |
| Telegram | 8081 | (internal) | `http://security-api-proxy:8081` |
| Brave Search | 8082 | (internal) | `http://security-api-proxy:8082` |
| GitHub API | 8083 | (internal) | `http://security-api-proxy:8083` |
| GitHub Git | 8084 | (internal) | `http://security-api-proxy:8084` |

## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2
- Linux host (Suricata needs `docker0` interface, Tracee needs eBPF/kernel support)
- Telegram bot token and chat ID (optional — alerts print to stdout without it)

## Setup

```bash
cd security
./setup.sh
```

The setup script will:
1. Check prerequisites (Docker, Compose v2)
2. Prompt for Telegram, LLM, Brave, and GitHub credentials
3. Extract and configure Suricata with ET Open rules
4. Build both proxy images
5. Pull all Docker images
6. Start all services
7. Run health checks on both proxies

## Wiring OpenClaw to Use the Proxies

Set these environment variables for the OpenClaw gateway container:

```bash
# LLM API (Anthropic/OpenAI) — through the FastAPI proxy
ANTHROPIC_BASE_URL=http://security-llm-proxy:8080

# Telegram — through the nginx proxy
TELEGRAM_API_BASE=http://security-api-proxy:8081

# Brave Search — through the nginx proxy
BRAVE_API_BASE=http://security-api-proxy:8082

# GitHub API — through the nginx proxy
GITHUB_API_BASE=http://security-api-proxy:8083

# GitHub Git — through the nginx proxy (use as git remote URL prefix)
# git clone http://security-api-proxy:8084/owner/repo.git
```

The proxies inject real API keys — OpenClaw doesn't need them in its own config.

If running OpenClaw outside Docker, use `http://localhost:18790` (LLM) and `http://localhost:18780` (API proxy health) instead.

## Manual Start (Without setup.sh)

```bash
cd security

# Copy and edit environment
cp .env.security.example .env.security
# Edit .env.security with your values

# Setup Suricata
bash suricata/setup.sh

# Start everything
docker compose -f docker-compose.security.yml up -d
```

## Testing

### Verify services are running
```bash
docker compose -f docker-compose.security.yml ps
```

### Health checks
```bash
# LLM proxy
curl http://localhost:18790/health
# {"status":"healthy","guard_enabled":false,"llm_api_base":"https://api.anthropic.com"}

# API proxy
curl http://localhost:18780/health
# {"status":"ok","services":["telegram","brave","github-api","github-git"],...}
```

### Test LLM Proxy forwarding
```bash
curl -X POST http://localhost:18790/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5-20250929","max_tokens":10,"messages":[{"role":"user","content":"Hi"}]}'
```

### Test Telegram proxy (from inside a container on openclaw_net)
```bash
curl http://security-api-proxy:8081/botFAKE/getMe
# Should proxy to Telegram with the real token injected
```

### Test Brave proxy (from inside a container on openclaw_net)
```bash
curl "http://security-api-proxy:8082/api/search?q=test"
# Should proxy to Brave Search with subscription token injected
```

### Test GitHub proxy (from inside a container on openclaw_net)
```bash
curl http://security-api-proxy:8083/user
# Should proxy to GitHub API with Bearer token injected
```

### Check Suricata
```bash
docker compose -f docker-compose.security.yml logs security-suricata
# Should show "engine started" and interface binding
```

### Check Tracee
```bash
docker compose -f docker-compose.security.yml logs security-tracee
# Should show policy loaded and initialization messages
```

### Trigger test alerts
```bash
# Tracee: exec into a container
docker exec -it openclaw-gateway /bin/sh

# Suricata: scan the Docker host (from another machine)
nmap <docker-host-ip>
```

## Adding a Guard Service

The LLM proxy has a built-in hook point for content scanning. To enable:

1. Add your guard container to `docker-compose.security.yml` on the `security-net` network
2. Set these values in `.env.security`:
   ```
   GUARD_URL=http://security-guard:8000/scan
   GUARD_ENABLED=true
   GUARD_THRESHOLD=0.8
   ```
3. Restart the proxy:
   ```bash
   docker compose -f docker-compose.security.yml restart security-llm-proxy
   ```

The guard service should accept POST requests with `{"messages": ["text1", "text2"]}` and return `{"score": 0.0-1.0, "reason": "..."}`.

## Configuration

### Environment Variables

All credentials live in `.env.security`. See `.env.security.example` for the full list.

| Variable | Used by | Purpose |
|----------|---------|---------|
| `TELEGRAM_BOT_TOKEN` | alerter, api-proxy | Telegram bot authentication |
| `TELEGRAM_CHAT_ID` | alerter | Alert destination chat |
| `LLM_API_BASE` | llm-proxy | LLM API endpoint |
| `LLM_API_KEY` | llm-proxy | LLM API authentication |
| `LLM_API_PROVIDER` | llm-proxy | `anthropic` or `openai` |
| `BRAVE_API_KEY` | api-proxy | Brave Search subscription token |
| `GITHUB_TOKEN` | api-proxy | GitHub PAT for API + git |
| `SECURITY_LLM_PROXY_PORT` | docker-compose | Host port for LLM proxy (default 18790) |
| `SECURITY_API_PROXY_PORT` | docker-compose | Host port for API proxy (default 18780) |

### Suricata Rules
```bash
docker run --rm -v "$(pwd)/suricata/rules:/var/lib/suricata/rules" \
  jasonish/suricata:latest suricata-update
docker compose -f docker-compose.security.yml restart security-suricata
```

### Tracee Policies
Edit `tracee/policies/openclaw.yaml` then restart:
```bash
docker compose -f docker-compose.security.yml restart security-tracee
```

### Alert Rate Limiting
Set `ALERT_MAX_PER_MINUTE` in `.env.security` (default: 10).

## Viewing Logs

| Log | Location |
|-----|----------|
| Suricata EVE | `suricata/logs/eve.json` |
| Tracee events | `/tmp/tracee/out` |
| LLM Proxy | `docker compose -f docker-compose.security.yml logs security-llm-proxy` |
| API Proxy | `docker compose -f docker-compose.security.yml logs security-api-proxy` |
| Alerter | `docker compose -f docker-compose.security.yml logs security-alerter` |

## Resource Usage

| Service | Approximate RAM |
|---------|----------------|
| Suricata | ~100 MB |
| Tracee | ~80 MB |
| LLM Proxy | ~100 MB |
| API Proxy | ~20 MB |
| Alerter | ~10 MB |
| **Total** | **~310 MB** |

## Network

Both `docker-compose.yml` (OpenClaw) and `docker-compose.security.yml` (this stack) share the `openclaw_net` network:

- `docker-compose.yml` defines it: `networks: { openclaw_net: {} }`
- `docker-compose.security.yml` references it: `networks: { openclaw_net: { external: true } }`

This means OpenClaw must be started first (or the network created manually) so it exists when the security stack starts.

## Troubleshooting

### Suricata not capturing traffic
- Verify the interface name: `docker network ls` — the bridge network uses `docker0` by default
- On some systems the interface may be named differently; update the `command` in `docker-compose.security.yml`

### Tracee errors
- Requires Linux kernel 5.4+ with eBPF support
- Must run as privileged with PID namespace access

### Telegram alerts not sending
- Verify bot token: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- Verify chat ID: send a message to the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`

### Proxy not reachable from OpenClaw container
- Ensure OpenClaw was started first so `openclaw_net` exists
- Check with `docker network ls | grep openclaw`
- From inside the OpenClaw container: `curl http://security-llm-proxy:8080/health`

### LLM Proxy returns 502
- Check that `LLM_API_BASE` is correct in `.env.security`
- Check that `LLM_API_KEY` is valid
- View proxy logs: `docker compose -f docker-compose.security.yml logs security-llm-proxy`

### API Proxy returns 502/503
- Check that the corresponding API key is set in `.env.security`
- View proxy logs: `docker compose -f docker-compose.security.yml logs security-api-proxy`

## Uninstall

```bash
cd security
docker compose -f docker-compose.security.yml down

# Remove runtime data
rm -rf suricata/logs suricata/etc suricata/rules /tmp/tracee/
```
