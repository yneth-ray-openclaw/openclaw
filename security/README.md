# OpenClaw Security & Proxy Stack

A Docker-based security enforcement and API proxy overlay for OpenClaw. Provides network IPS (inline packet inspection with active blocking), container runtime enforcement (SIGKILL on critical violations), a transparent LLM API proxy with guard hooks, an nginx-based API proxy for external services, and unified Telegram alerting — without modifying any existing OpenClaw files.

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
     | (FastAPI)       |  | (nginx+njs)      |
     | :8080 -> LLM    |  | :8081 Telegram   |
     | guard hooks     |  | :8082 Brave      |
     | streaming       |  | :8083 GitHub API |
     +--------+--------+  | :8084 GitHub Git |
              |            | :8085 Google API |
      Anthropic / OpenAI   | :8086 Viber API  |
                           +--+-+-+--+--+--+-+
                              | | |  |  |  |
                        Telegram Brave GitHub Google Viber

  +---------------------+    +---------------------+
  | security-suricata   |    | security-tracee     |
  | network_mode: host  |    | privileged, pid:host|
  | IPS: NFQUEUE inline |    | enforcement: SIGKILL|
  | DROP malicious pkts |    | kills critical viols|
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
               | daily summary   |
               +-----------------+
```

## Components

| Service       | Container            | Purpose                                                                                                                                               |
| ------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **LLM Proxy** | `security-llm-proxy` | FastAPI reverse proxy for Anthropic/OpenAI. Hides API key, supports streaming, guard-ready hook point. Distroless Python image.                       |
| **API Proxy** | `security-api-proxy` | nginx+njs reverse proxy for Telegram, Brave Search, GitHub API, GitHub Git, Google API, Viber. Injects auth per-service. Chainguard image (no shell). |
| **Suricata**  | `security-suricata`  | Network IPS — inline NFQUEUE inspection on FORWARD chain, drops malicious packets. ET Open + SSLBL + etnetera/aggressive feeds.                       |
| **Tracee**    | `security-tracee`    | Runtime enforcement — eBPF-based container monitoring with SIGKILL on critical violations                                                             |
| **Alerter**   | `security-alerter`   | Aggregates Suricata and Tracee alerts, sends to Telegram. Daily traffic summary.                                                                      |

## Container Hardening

### Minimal Base Images

The proxy containers use minimal/distroless base images to reduce attack surface:

- **API Proxy:** `cgr.dev/chainguard/nginx` — Chainguard's hardened nginx image with njs module. No shell, no package manager, no coreutils.
- **LLM Proxy:** `gcr.io/distroless/python3-debian12:nonroot` — Google's distroless Python image. No shell, no package manager.
- **Alerter:** `alpine:3.21` with only `curl` and `jq` added.

Both proxy images use a shared static Go healthcheck binary instead of curl/wget for container health checks.

### Why Not mTLS / Access Control Between Agent and Proxy

The OpenClaw agent is the sole consumer of both proxies. mTLS, shared secrets, per-service networks, and other access control schemes between agent and proxy provide no real security benefit: if the agent is compromised, the attacker has the client certificate (or secret, or network access) too. Instead, security is provided by:

- Distroless/minimal images (no tools for an attacker to use)
- Read-only filesystems
- Dropped capabilities (all capabilities dropped)
- `no-new-privileges` security option
- Rate limiting at the nginx level

### Docker Compose Security Options

All services have `security_opt: [no-new-privileges:true]`. The proxy and alerter containers additionally have:

- `read_only: true` — filesystem is read-only (tmpfs mounts for required writable dirs)
- `cap_drop: [ALL]` — all Linux capabilities dropped

### njs-Based Token Rotation

The API proxy uses nginx's njs JavaScript module to handle Google OAuth2 token rotation entirely within nginx — no shell scripts, no `curl`, no config rewrite, no `nginx -s reload`:

- `js_periodic` refreshes the Google token every 45 minutes via `ngx.fetch()`
- `js_shared_dict_zone` stores the token in nginx shared memory
- `js_set` injects all tokens (static from env + rotating from shared dict) into `proxy_set_header` per-request

## Active Enforcement

Both Suricata and Tracee run in **active enforcement mode** — they detect AND block threats in real time.

### Suricata IPS (Inline Packet Inspection)

Suricata runs as an inline IPS using NFQUEUE. All FORWARD-chain traffic (container-to-container and container-to-internet) passes through Suricata for inspection. Rules with `drop` action will block matching packets.

- **FORWARD chain only** — host INPUT/OUTPUT traffic (SSH, docker daemon) is never affected
- **Fail-closed** — if Suricata crashes, NFQUEUE packets have no consumer and traffic is blocked. The `restart: unless-stopped` policy ensures quick recovery.
- Alerts are still written to `eve.json` for both `alert` and `drop` actions

### Tracee Enforcement (SIGKILL)

Tracee enforces critical security policies by immediately killing offending processes:

| Event                | Action   | Rationale                                                    |
| -------------------- | -------- | ------------------------------------------------------------ |
| `ptrace`             | SIGKILL  | Process injection — almost always malicious in containers    |
| `init_module`        | SIGKILL  | Kernel module loading from container = container escape      |
| `finit_module`       | SIGKILL  | Same (file-based variant)                                    |
| `setuid`             | SIGKILL  | Privilege escalation — OpenClaw runs as `node`, no legit use |
| `setgid`             | SIGKILL  | Same                                                         |
| `security_file_open` | log only | Too broad to kill — many legitimate file opens               |
| `sched_process_exec` | log only | Would break the container                                    |
| `net_packet_ipv4`    | log only | Network monitoring only                                      |

All events (both enforced and monitored) still generate log output for the alerter.

## Threat Intelligence & Blocking

### Enabled Feeds

The Suricata IPS uses multiple threat intelligence feeds:

| Feed                       | Source           | Content                                                      |
| -------------------------- | ---------------- | ------------------------------------------------------------ |
| **ET Open**                | Emerging Threats | 64k+ rules covering malware, C2, exploits, policy violations |
| **SSLBL ssl-fp-blacklist** | abuse.ch         | Malicious SSL certificate fingerprints                       |
| **SSLBL ja3-fingerprints** | abuse.ch         | Malicious JA3 TLS client fingerprints                        |
| **etnetera/aggressive**    | Etnetera         | Aggressive threat detection rules                            |

### Drop Rule Categories

The following rule categories are converted from `alert` to `drop` (active blocking) via `modify.conf`:

| Category                   | Description                            |
| -------------------------- | -------------------------------------- |
| `trojan-activity`          | Malware/trojan communication           |
| `command-and-control`      | C2 beaconing and callbacks             |
| `exploit-kit`              | Exploit kit delivery and landing pages |
| `web-application-attack`   | SQL injection, XSS, RFI, etc.          |
| `attempted-admin`          | Unauthorized admin access attempts     |
| `shellcode-detect`         | Shellcode in network traffic           |
| `successful-admin`         | Successful unauthorized admin access   |
| `successful-recon-limited` | Successful reconnaissance activity     |

All other categories remain as `alert` (log only) to avoid false-positive blocking of legitimate traffic.

### Automatic Rule Updates

Suricata rules are updated automatically at the configured hour (`RULE_UPDATE_HOUR`, default: 3 AM). The update process:

1. Runs `suricata-update` with the `modify.conf` to fetch latest rules and apply drop conversions
2. Triggers a live rule reload via `suricatasc -c reload-rules` (no restart needed)

### Adding Custom Blocklists

To add additional `suricata-update` sources:

```bash
# List available sources
docker exec security-suricata suricata-update list-sources

# Enable a source
docker exec security-suricata suricata-update enable-source <source-name>

# Update rules
docker exec security-suricata suricata-update --modify-conf /var/lib/suricata/rules/modify.conf
docker exec security-suricata suricatasc -c reload-rules
```

## Daily Traffic Summary

The alerter sends a daily traffic summary to Telegram at the configured hour (`DAILY_REPORT_HOUR`, default: midnight). The report includes:

- **DNS Queries:** Top queried domains with counts
- **HTTP/TLS Destinations:** Top destination IPs with hostnames (from SNI/Host header)
- **Alerts:** Summary of triggered alert rules with counts
- **Blocked:** Count of packets actively dropped by IPS rules

This requires DNS, HTTP, and TLS logging enabled in Suricata (configured by `setup.sh`).

## Port Reference

| Service          | Container Port | Host Port  | Access from OpenClaw                    |
| ---------------- | -------------- | ---------- | --------------------------------------- |
| LLM Proxy        | 8080           | 10001      | `http://security-llm-proxy:8080`        |
| API Proxy health | 8080           | 10000      | `http://security-api-proxy:8080/health` |
| Telegram         | 8081           | (internal) | `http://security-api-proxy:8081`        |
| Brave Search     | 8082           | (internal) | `http://security-api-proxy:8082`        |
| GitHub API       | 8083           | (internal) | `http://security-api-proxy:8083`        |
| GitHub Git       | 8084           | (internal) | `http://security-api-proxy:8084`        |
| Google API       | 8085           | (internal) | `http://security-api-proxy:8085`        |
| Viber API        | 8086           | (internal) | `http://security-api-proxy:8086`        |

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
2. Prompt for Telegram, LLM, Brave, GitHub, Google, and Viber credentials
3. Extract and configure Suricata with ET Open + SSLBL rules and drop rules
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

# Google API (Calendar/Gmail/Drive) — through the nginx proxy
GOOGLE_API_BASE=http://security-api-proxy:8085

# Viber API — through the nginx proxy
VIBER_API_BASE=http://security-api-proxy:8086
```

The proxies inject real API keys — OpenClaw doesn't need them in its own config.

If running OpenClaw outside Docker, use `http://localhost:10001` (LLM) and `http://localhost:10000` (API proxy health) instead.

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
curl http://localhost:10001/health
# {"status":"healthy","guard_enabled":false,"llm_api_base":"https://api.anthropic.com"}

# API proxy
curl http://localhost:10000/health
# {"status":"ok","services":["telegram","brave","github-api","github-git"],...}
```

### Test LLM Proxy forwarding

```bash
curl -X POST http://localhost:10001/v1/messages \
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

### Test Google API proxy (from inside a container on openclaw_net)

```bash
curl http://security-api-proxy:8085/calendar/v3/calendars/primary/events?maxResults=1
# Should proxy to Google API with OAuth2 Bearer token injected
```

### Test Viber proxy (from inside a container on openclaw_net)

```bash
curl -X POST http://security-api-proxy:8086/get_account_info \
  -H "Content-Type: application/json" -d '{}'
# Should proxy to Viber API with auth token injected
```

### Verify no shell in proxy containers

```bash
docker exec security-api-proxy sh
# Should fail — no shell in Chainguard image
```

### Verify read-only filesystem

```bash
docker exec security-api-proxy touch /test
# Should fail — read-only filesystem
```

### Check Suricata IPS

```bash
docker compose -f docker-compose.security.yml logs security-suricata
# Should show "IPS mode (NFQUEUE 0)" and "engine started"

# Verify NFQUEUE rule is active
docker exec security-suricata iptables -L FORWARD -n
# Should show NFQUEUE target

# Verify threat feeds
docker exec security-suricata suricata-update list-enabled-sources
# Should show ET Open + SSLBL sources

# Verify drop rules
grep -c "^drop " suricata/rules/suricata.rules
# Should show many drop rules for critical categories
```

### Check Tracee Enforcement

```bash
docker compose -f docker-compose.security.yml logs security-tracee
# Should show policy loaded with enforcement actions

# Test enforcement: ptrace attempt should be killed
docker exec openclaw-gateway strace -p 1
# Should be immediately terminated by Tracee's sigkill action
```

### Trigger test alerts

```bash
# Tracee: exec into a container
docker exec -it openclaw-gateway /bin/sh

# Suricata: scan the Docker host (from another machine)
nmap <docker-host-ip>
```

### Test daily report manually

```bash
docker exec security-alerter sh /daily-report.sh
# Should send a traffic summary to Telegram (or print to stdout)
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

| Variable                  | Used by            | Purpose                                             |
| ------------------------- | ------------------ | --------------------------------------------------- |
| `TELEGRAM_BOT_TOKEN`      | alerter, api-proxy | Telegram bot authentication                         |
| `TELEGRAM_CHAT_ID`        | alerter            | Alert destination chat                              |
| `LLM_API_BASE`            | llm-proxy          | LLM API endpoint                                    |
| `LLM_API_KEY`             | llm-proxy          | LLM API authentication                              |
| `LLM_API_PROVIDER`        | llm-proxy          | `anthropic` or `openai`                             |
| `BRAVE_API_KEY`           | api-proxy          | Brave Search subscription token                     |
| `GITHUB_TOKEN`            | api-proxy          | GitHub PAT for API + git                            |
| `GOOGLE_CLIENT_ID`        | api-proxy          | Google OAuth2 client ID                             |
| `GOOGLE_CLIENT_SECRET`    | api-proxy          | Google OAuth2 client secret                         |
| `GOOGLE_REFRESH_TOKEN`    | api-proxy          | Google OAuth2 refresh token                         |
| `VIBER_BOT_TOKEN`         | api-proxy          | Viber bot authentication token                      |
| `DAILY_REPORT_HOUR`       | alerter            | Hour (0-23) for daily traffic summary (default: 0)  |
| `RULE_UPDATE_HOUR`        | suricata           | Hour (0-23) for automatic rule updates (default: 3) |
| `SECURITY_LLM_PROXY_PORT` | docker-compose     | Host port for LLM proxy (default 10001)             |
| `SECURITY_API_PROXY_PORT` | docker-compose     | Host port for API proxy (default 10000)             |

### Suricata Rules

Rules are updated automatically at `RULE_UPDATE_HOUR`. To update manually:

```bash
docker exec security-suricata suricata-update \
  --modify-conf /var/lib/suricata/rules/modify.conf
docker exec security-suricata suricatasc -c reload-rules
```

The `modify.conf` file converts critical threat categories from `alert` to `drop`. See "Threat Intelligence & Blocking" above for the full list.

### Tracee Policies

Edit `tracee/policies/openclaw.yaml` then restart:

```bash
docker compose -f docker-compose.security.yml restart security-tracee
```

### Alert Rate Limiting

Set `ALERT_MAX_PER_MINUTE` in `.env.security` (default: 10).

## Viewing Logs

| Log           | Location                                                                |
| ------------- | ----------------------------------------------------------------------- |
| Suricata EVE  | `suricata/logs/eve.json`                                                |
| Tracee events | `/tmp/tracee/out`                                                       |
| LLM Proxy     | `docker compose -f docker-compose.security.yml logs security-llm-proxy` |
| API Proxy     | `docker compose -f docker-compose.security.yml logs security-api-proxy` |
| Alerter       | `docker compose -f docker-compose.security.yml logs security-alerter`   |

## Resource Usage

| Service   | Approximate RAM |
| --------- | --------------- |
| Suricata  | ~100 MB         |
| Tracee    | ~80 MB          |
| LLM Proxy | ~100 MB         |
| API Proxy | ~20 MB          |
| Alerter   | ~10 MB          |
| **Total** | **~310 MB**     |

## Network

Both `docker-compose.yml` (OpenClaw) and `docker-compose.security.yml` (this stack) share the `openclaw_net` network:

- `docker-compose.yml` defines it: `networks: { openclaw_net: {} }`
- `docker-compose.security.yml` references it: `networks: { openclaw_net: { external: true } }`

This means OpenClaw must be started first (or the network created manually) so it exists when the security stack starts.

## Troubleshooting

### Suricata not blocking traffic

- Verify NFQUEUE is active: `docker exec security-suricata iptables -L FORWARD -n` — should show NFQUEUE rule
- Check Suricata logs: `docker compose -f docker-compose.security.yml logs security-suricata` — should show "IPS mode (NFQUEUE 0)"
- If all traffic is blocked, Suricata may have crashed. Check logs and restart: `docker compose -f docker-compose.security.yml restart security-suricata`

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
