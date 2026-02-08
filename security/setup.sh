#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Banner ---
echo "╔══════════════════════════════════════════════════╗"
echo "║   OpenClaw Security & Proxy Stack Setup          ║"
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
    echo "  The security stack can start without it, but the openclaw_net Docker"
    echo "  network must exist. Run 'docker compose up -d' from the project root first."
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

    # Telegram (used by alerter + api-proxy)
    read -p "  Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    read -p "  Telegram Chat ID: " TELEGRAM_CHAT_ID

    # LLM Proxy (FastAPI)
    read -p "  LLM API Key: " LLM_API_KEY
    read -p "  LLM API Base [https://api.anthropic.com]: " LLM_API_BASE
    LLM_API_BASE="${LLM_API_BASE:-https://api.anthropic.com}"
    read -p "  LLM API Provider [anthropic]: " LLM_API_PROVIDER
    LLM_API_PROVIDER="${LLM_API_PROVIDER:-anthropic}"

    # Brave Search (optional)
    echo ""
    echo "  Optional: Brave Search API key (for web search proxy)"
    read -p "  Brave API Key [skip]: " BRAVE_API_KEY
    BRAVE_API_KEY="${BRAVE_API_KEY:-}"

    # GitHub (optional)
    echo ""
    echo "  Optional: GitHub token (for API & git proxy)"
    read -p "  GitHub Token [skip]: " GITHUB_TOKEN
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"

    # Host Ports
    read -p "  LLM Proxy Host Port [18790]: " SECURITY_LLM_PROXY_PORT
    SECURITY_LLM_PROXY_PORT="${SECURITY_LLM_PROXY_PORT:-18790}"
    read -p "  API Proxy Host Port [18780]: " SECURITY_API_PROXY_PORT
    SECURITY_API_PROXY_PORT="${SECURITY_API_PROXY_PORT:-18780}"

    cat > .env.security <<EOF
# Telegram (used by alerter AND api-proxy)
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}

# Alert Rate Limiting
ALERT_MAX_PER_MINUTE=10

# LLM Proxy (FastAPI) — Anthropic/OpenAI
LLM_API_BASE=${LLM_API_BASE}
LLM_API_KEY=${LLM_API_KEY}
LLM_API_PROVIDER=${LLM_API_PROVIDER}

# Brave Search (optional)
BRAVE_API_KEY=${BRAVE_API_KEY}

# GitHub (optional)
GITHUB_TOKEN=${GITHUB_TOKEN}

# Host Ports
SECURITY_LLM_PROXY_PORT=${SECURITY_LLM_PROXY_PORT}
SECURITY_API_PROXY_PORT=${SECURITY_API_PROXY_PORT}

# Future: Guard service
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

LLM_PROXY_PORT=$(grep SECURITY_LLM_PROXY_PORT .env.security 2>/dev/null | head -1 | cut -d= -f2-)
LLM_PROXY_PORT="${LLM_PROXY_PORT:-18790}"

API_PROXY_PORT=$(grep SECURITY_API_PROXY_PORT .env.security 2>/dev/null | head -1 | cut -d= -f2-)
API_PROXY_PORT="${API_PROXY_PORT:-18780}"

LLM_API_BASE_DISPLAY=$(grep LLM_API_BASE .env.security 2>/dev/null | head -1 | cut -d= -f2-)
LLM_API_BASE_DISPLAY="${LLM_API_BASE_DISPLAY:-https://api.anthropic.com}"

# Check LLM proxy
echo "  Waiting for LLM proxy on port ${LLM_PROXY_PORT}..."
llm_healthy=false
for i in $(seq 1 15); do
    if curl -sf "http://localhost:${LLM_PROXY_PORT}/health" > /dev/null 2>&1; then
        llm_healthy=true
        break
    fi
    sleep 2
done

if [ "$llm_healthy" = true ]; then
    echo "  [OK] LLM proxy is healthy"
else
    echo "  [WARN] LLM proxy health check timed out (may still be starting)"
fi

# Check API proxy
echo "  Waiting for API proxy on port ${API_PROXY_PORT}..."
api_healthy=false
for i in $(seq 1 15); do
    if curl -sf "http://localhost:${API_PROXY_PORT}/health" > /dev/null 2>&1; then
        api_healthy=true
        break
    fi
    sleep 2
done

if [ "$api_healthy" = true ]; then
    echo "  [OK] API proxy is healthy"
else
    echo "  [WARN] API proxy health check timed out (may still be starting)"
fi

echo ""
echo "  Running containers:"
docker ps --filter name=security- --format "    {{.Names}}: {{.Status}}"
echo ""

# --- Summary ---
echo "╔══════════════════════════════════════════════════╗"
echo "║   Security & Proxy stack is running!             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Services:"
echo "  * Suricata (Network IDS) — monitoring docker0"
echo "  * Tracee (Runtime Security) — monitoring containers"
echo "  * LLM Proxy (FastAPI) — forwarding to ${LLM_API_BASE_DISPLAY}"
echo "  * API Proxy (nginx) — Telegram, Brave, GitHub"
echo "  * Alerter — sending alerts to Telegram"
echo ""
echo "Proxy Endpoints (from inside OpenClaw containers):"
echo "  LLM (Anthropic/OpenAI): http://security-llm-proxy:8080"
echo "  Telegram:               http://security-api-proxy:8081"
echo "  Brave Search:           http://security-api-proxy:8082"
echo "  GitHub API:             http://security-api-proxy:8083"
echo "  GitHub Git:             http://security-api-proxy:8084"
echo ""
echo "Host-side health checks:"
echo "  curl http://localhost:${LLM_PROXY_PORT}/health"
echo "  curl http://localhost:${API_PROXY_PORT}/health"
echo ""
echo "View logs:"
echo "  docker compose -f docker-compose.security.yml logs -f"
echo ""
