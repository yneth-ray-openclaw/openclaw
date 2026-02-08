# OpenClaw Security Monitoring Stack

A Docker-based security monitoring overlay for OpenClaw. Adds network IDS, container runtime security, a transparent LLM API proxy, and unified Telegram alerting — without modifying any existing OpenClaw files.

## Architecture Overview

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
            |    +----------------------+   |
            +--->| security-llm-proxy   |<--+
                 | (port 8080)          |
                 | strips auth headers  |
                 | injects real API key |
                 +----------+-----------+
                            |
                    LLM API (Anthropic/OpenAI)

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

| Service | Purpose |
|---------|---------|
| **Suricata** | Network IDS — monitors docker0 bridge with ET Open rules, detects network-level threats |
| **Tracee** | Runtime security — eBPF-based container monitoring for privilege escalation, suspicious exec, kernel module loading |
| **LLM Proxy** | Transparent reverse proxy for LLM API calls. Hides real API key, supports streaming. Guard-ready hook point for future content scanning |
| **Alerter** | Aggregates Suricata and Tracee alerts, sends to Telegram with rate limiting |

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
2. Prompt for Telegram credentials and LLM API key
3. Extract and configure Suricata with ET Open rules
4. Build the LLM proxy image
5. Pull all Docker images
6. Start all services
7. Run health checks

## Configuring OpenClaw to Use LLM Proxy

Edit `~/.openclaw/config.json5` and add a custom provider pointing to the proxy:

```json5
{
  // ... existing config ...
  baseUrl: "http://security-llm-proxy:8080"
}
```

The proxy injects the real API key — OpenClaw doesn't need it in its own config. This means the API key is only stored in `security/.env.security`.

If running OpenClaw outside Docker, use `http://localhost:8080` instead.

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

### Check LLM Proxy
```bash
curl http://localhost:8080/health
# {"status":"healthy","guard_enabled":false,"llm_api_base":"https://api.anthropic.com"}
```

### Test LLM Proxy forwarding
```bash
curl -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5-20250929","max_tokens":10,"messages":[{"role":"user","content":"Hi"}]}'
```

### Check Alerter
```bash
docker compose -f docker-compose.security.yml logs security-alerter
# Should show "Starting log monitoring..."
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

## Viewing Logs

| Log | Location |
|-----|----------|
| Suricata EVE | `suricata/logs/eve.json` |
| Tracee events | `/tmp/tracee/out` |
| LLM Proxy | `docker compose -f docker-compose.security.yml logs security-llm-proxy` |
| Alerter | `docker compose -f docker-compose.security.yml logs security-alerter` |

## Configuration

### Suricata Rules
Rules are downloaded during setup via `suricata-update`. To update:
```bash
docker run --rm -v "$(pwd)/suricata/rules:/var/lib/suricata/rules" \
  jasonish/suricata:latest suricata-update
docker compose -f docker-compose.security.yml restart security-suricata
```

### Tracee Policies
Edit `tracee/policies/openclaw.yaml` to add or remove monitored events, then restart:
```bash
docker compose -f docker-compose.security.yml restart security-tracee
```

### Alert Rate Limiting
Set `ALERT_MAX_PER_MINUTE` in `.env.security` (default: 10).

### LLM API Backend
Change `LLM_API_BASE` and `LLM_API_PROVIDER` in `.env.security` to point to a different API.

## Resource Usage

| Service | Approximate RAM |
|---------|----------------|
| Suricata | ~100 MB |
| Tracee | ~80 MB |
| LLM Proxy | ~100 MB |
| Alerter | ~10 MB |
| **Total** | **~300 MB** |

## Troubleshooting

### Suricata not capturing traffic
- Verify the interface name: `docker network ls` — the bridge network uses `docker0` by default
- On some systems the interface may be named differently; update the `command` in `docker-compose.security.yml`
- Check `docker compose -f docker-compose.security.yml logs security-suricata` for binding errors

### Tracee errors
- Requires Linux kernel 5.4+ with eBPF support
- Must run as privileged with PID namespace access
- Check `docker compose -f docker-compose.security.yml logs security-tracee` for kernel compatibility messages

### Telegram alerts not sending
- Verify bot token: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- Verify chat ID: send a message to the bot, then check `https://api.telegram.org/bot<TOKEN>/getUpdates`
- Check alerter logs for error messages

### LLM Proxy not reachable from OpenClaw container
- Ensure OpenClaw and the proxy are on the same Docker network (`openclaw_default`)
- From inside the OpenClaw container: `curl http://security-llm-proxy:8080/health`
- If using `localhost`, ensure port 8080 is published (it is by default)

### Proxy returns 502
- Check that `LLM_API_BASE` is correct in `.env.security`
- Check that `LLM_API_KEY` is valid
- View proxy logs: `docker compose -f docker-compose.security.yml logs security-llm-proxy`

## Uninstall

```bash
# Stop and remove all security containers
cd security
docker compose -f docker-compose.security.yml down

# Remove the security directory
cd ..
rm -rf security/

# Remove runtime data
rm -rf /tmp/tracee/

# Remove root .gitignore entries (optional)
# Delete the "Security monitoring stack" section from .gitignore
```
