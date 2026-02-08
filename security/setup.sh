#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Banner ---
echo "╔══════════════════════════════════════════════════╗"
echo "║   OpenClaw Security Monitoring Stack Setup       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# --- Check prerequisites ---
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "ERROR: docker is not installed or not in PATH."
    echo "Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi
echo "  [OK] docker found"

if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose v2 is not available."
    echo "Install Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi
echo "  [OK] docker compose v2 found"
echo ""

# --- Check OpenClaw status ---
echo "Checking OpenClaw status..."
if docker ps --format '{{.Names}}' | grep -q openclaw-gateway; then
    echo "  [OK] openclaw-gateway is running"
else
    echo "  [WARN] openclaw-gateway is not running."
    echo "  The security stack can start without it, but the openclaw_default"
    echo "  network must exist for the LLM proxy to connect."
    read -p "  Continue anyway? [y/N] " confirm
    if [ "${confirm,,}" != "y" ]; then
        echo "Aborted."
        exit 1
    fi
fi
echo ""

# --- Create directory structure ---
echo "Creating directory structure..."
mkdir -p suricata/{etc,rules,logs} tracee/policies
echo "  [OK] Directories created"
echo ""

# --- Environment configuration ---
echo "Configuring environment..."
if [ -f ".env.security" ]; then
    echo "  .env.security already exists. Skipping configuration."
    echo "  Edit .env.security manually to change settings."
else
    echo "  Enter your configuration values (press Enter for defaults):"
    echo ""

    read -p "  Telegram Bot Token: " TG_BOT_TOKEN
    read -p "  Telegram Chat ID: " TG_CHAT_ID
    read -p "  LLM API Key: " LLM_API_KEY
    read -p "  LLM API Base [https://api.anthropic.com]: " LLM_API_BASE
    LLM_API_BASE="${LLM_API_BASE:-https://api.anthropic.com}"
    read -p "  LLM API Provider [anthropic]: " LLM_API_PROVIDER
    LLM_API_PROVIDER="${LLM_API_PROVIDER:-anthropic}"

    cat > .env.security <<EOF
# Telegram Alerting
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}

# Alert Rate Limiting
ALERT_MAX_PER_MINUTE=10

# LLM Proxy
LLM_API_BASE=${LLM_API_BASE}
LLM_API_KEY=${LLM_API_KEY}
LLM_API_PROVIDER=${LLM_API_PROVIDER}

# Future: Guard service URL (uncomment when a guard is added)
# GUARD_URL=http://security-guard:8000/scan
# GUARD_ENABLED=true
# GUARD_THRESHOLD=0.8
EOF

    echo "  [OK] Configuration saved to .env.security"
fi
echo ""

# --- Suricata setup ---
echo "Setting up Suricata..."
bash suricata/setup.sh
echo ""

# --- Build Docker images ---
echo "Building Docker images..."
docker compose -f docker-compose.security.yml build
echo "  [OK] Images built"
echo ""

# --- Pull Docker images ---
echo "Pulling Docker images..."
docker compose -f docker-compose.security.yml pull --ignore-buildable
echo "  [OK] Images pulled"
echo ""

# --- Start all services ---
echo "Starting security services..."
docker compose -f docker-compose.security.yml up -d
echo "  [OK] Services started"
echo ""

# --- Health checks ---
echo "Running health checks..."
LLM_API_BASE_DISPLAY=$(grep LLM_API_BASE .env.security 2>/dev/null | head -1 | cut -d= -f2-)
LLM_API_BASE_DISPLAY="${LLM_API_BASE_DISPLAY:-https://api.anthropic.com}"

echo "  Waiting for LLM proxy..."
healthy=false
for i in $(seq 1 15); do
    if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        healthy=true
        break
    fi
    sleep 2
done

if [ "$healthy" = true ]; then
    echo "  [OK] LLM proxy is healthy"
else
    echo "  [WARN] LLM proxy health check timed out (may still be starting)"
fi

echo ""
echo "  Running containers:"
docker ps --filter name=security- --format "    {{.Names}}: {{.Status}}"
echo ""

# --- Summary ---
echo "╔══════════════════════════════════════════════════╗"
echo "║   Security stack is running!                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Services:"
echo "  * Suricata (Network IDS) - monitoring docker0"
echo "  * Tracee (Runtime Security) - monitoring containers"
echo "  * LLM Proxy - forwarding to ${LLM_API_BASE_DISPLAY}"
echo "  * Alerter - sending alerts to Telegram"
echo ""
echo "Next steps:"
echo "  1. Configure OpenClaw to use the proxy:"
echo "     Edit ~/.openclaw/config.json5 and set baseUrl to:"
echo "     http://security-llm-proxy:8080"
echo ""
echo "  2. View logs:"
echo "     docker compose -f docker-compose.security.yml logs -f"
echo ""
echo "  3. Test the proxy:"
echo "     curl http://localhost:8080/health"
echo ""
