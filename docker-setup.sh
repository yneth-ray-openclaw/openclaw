#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
EXTRA_COMPOSE_FILE="$ROOT_DIR/docker-compose.extra.yml"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"
EXTRA_MOUNTS="${OPENCLAW_EXTRA_MOUNTS:-}"
HOME_VOLUME_NAME="${OPENCLAW_HOME_VOLUME:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose not available (try: docker compose version)" >&2
  exit 1
fi

OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"

export OPENCLAW_CONFIG_DIR
export OPENCLAW_WORKSPACE_DIR
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
export OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
export OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
export OPENCLAW_IMAGE="$IMAGE_NAME"
export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
export OPENCLAW_UID="${OPENCLAW_UID:-$(id -u)}"
export OPENCLAW_GID="${OPENCLAW_GID:-$(id -g)}"
export OPENCLAW_EXTRA_MOUNTS="$EXTRA_MOUNTS"
export OPENCLAW_HOME_VOLUME="$HOME_VOLUME_NAME"

# Reuse gateway token from prior run so it stays consistent with openclaw.json
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" && -f "$ROOT_DIR/.env" ]]; then
  _prev_token="$(grep -m1 '^OPENCLAW_GATEWAY_TOKEN=' "$ROOT_DIR/.env" 2>/dev/null | cut -d= -f2-)"
  [[ -n "$_prev_token" ]] && export OPENCLAW_GATEWAY_TOKEN="$_prev_token"
  unset _prev_token
fi

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    OPENCLAW_GATEWAY_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  fi
fi
export OPENCLAW_GATEWAY_TOKEN

COMPOSE_FILES=("$COMPOSE_FILE")
COMPOSE_ARGS=()

write_extra_compose() {
  local home_volume="$1"
  shift
  local mount

  cat >"$EXTRA_COMPOSE_FILE" <<'YAML'
services:
  openclaw-gateway:
    volumes:
YAML

  if [[ -n "$home_volume" ]]; then
    printf '      - %s:/home/node\n' "$home_volume" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw\n' "$OPENCLAW_CONFIG_DIR" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw/workspace\n' "$OPENCLAW_WORKSPACE_DIR" >>"$EXTRA_COMPOSE_FILE"
  fi
  for mount in "$@"; do
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  cat >>"$EXTRA_COMPOSE_FILE" <<'YAML'
  openclaw-cli:
    volumes:
YAML

  if [[ -n "$home_volume" ]]; then
    printf '      - %s:/home/node\n' "$home_volume" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw\n' "$OPENCLAW_CONFIG_DIR" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw/workspace\n' "$OPENCLAW_WORKSPACE_DIR" >>"$EXTRA_COMPOSE_FILE"
  fi
  for mount in "$@"; do
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  if [[ -n "$home_volume" && "$home_volume" != *"/"* ]]; then
    cat >>"$EXTRA_COMPOSE_FILE" <<YAML
volumes:
  ${home_volume}:
YAML
  fi
}

VALID_MOUNTS=()
if [[ -n "$EXTRA_MOUNTS" ]]; then
  IFS=',' read -r -a mounts <<<"$EXTRA_MOUNTS"
  for mount in "${mounts[@]}"; do
    mount="${mount#"${mount%%[![:space:]]*}"}"
    mount="${mount%"${mount##*[![:space:]]}"}"
    if [[ -n "$mount" ]]; then
      VALID_MOUNTS+=("$mount")
    fi
  done
fi

if [[ -n "$HOME_VOLUME_NAME" ]] || [[ ${#VALID_MOUNTS[@]} -gt 0 ]]; then
  if [[ ${#VALID_MOUNTS[@]} -gt 0 ]]; then
    write_extra_compose "$HOME_VOLUME_NAME" "${VALID_MOUNTS[@]}"
  else
    write_extra_compose "$HOME_VOLUME_NAME"
  fi
  COMPOSE_FILES+=("$EXTRA_COMPOSE_FILE")
fi

# Allow external scripts to inject additional compose override files.
# OPENCLAW_COMPOSE_OVERRIDES is a colon-separated list of file paths.
if [[ -n "${OPENCLAW_COMPOSE_OVERRIDES:-}" ]]; then
  IFS=':' read -r -a _ovr_files <<< "$OPENCLAW_COMPOSE_OVERRIDES"
  for _ovr in "${_ovr_files[@]}"; do
    _ovr="${_ovr#"${_ovr%%[![:space:]]*}"}"
    _ovr="${_ovr%"${_ovr##*[![:space:]]}"}"
    [[ -n "$_ovr" && -f "$_ovr" ]] && COMPOSE_FILES+=("$_ovr")
  done
  unset _ovr_files _ovr
fi

for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=("-f" "$compose_file")
done
COMPOSE_HINT="docker compose"
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_HINT+=" -f ${compose_file}"
done

ENV_FILE="$ROOT_DIR/.env"
upsert_env() {
  local file="$1"
  shift
  local -a keys=("$@")
  local tmp
  tmp="$(mktemp)"
  # Use a delimited string instead of an associative array so the script
  # works with Bash 3.2 (macOS default) which lacks `declare -A`.
  local seen=" "

  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      local key="${line%%=*}"
      local replaced=false
      for k in "${keys[@]}"; do
        if [[ "$key" == "$k" ]]; then
          printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
          seen="$seen$k "
          replaced=true
          break
        fi
      done
      if [[ "$replaced" == false ]]; then
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi

  for k in "${keys[@]}"; do
    if [[ "$seen" != *" $k "* ]]; then
      printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
    fi
  done

  mv "$tmp" "$file"
}

upsert_env "$ENV_FILE" \
  OPENCLAW_CONFIG_DIR \
  OPENCLAW_WORKSPACE_DIR \
  OPENCLAW_GATEWAY_PORT \
  OPENCLAW_BRIDGE_PORT \
  OPENCLAW_GATEWAY_BIND \
  OPENCLAW_GATEWAY_TOKEN \
  OPENCLAW_IMAGE \
  OPENCLAW_EXTRA_MOUNTS \
  OPENCLAW_HOME_VOLUME \
  OPENCLAW_DOCKER_APT_PACKAGES \
  OPENCLAW_UID \
  OPENCLAW_GID \
  OPENCLAW_GATEWAY_URL

echo "==> Building Docker image: $IMAGE_NAME"
docker build \
  --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
  -t "$IMAGE_NAME" \
  -f "$ROOT_DIR/Dockerfile" \
  "$ROOT_DIR"

echo ""
echo "==> Onboarding (interactive)"
echo "When prompted:"
echo "  - Gateway bind: lan"
echo "  - Gateway auth: token"
echo "  - Gateway token: $OPENCLAW_GATEWAY_TOKEN"
echo "  - Tailscale exposure: Off"
echo "  - Install Gateway daemon: No"
echo ""
# Clean stale device auth/pairing from prior runs
rm -f "${OPENCLAW_CONFIG_DIR}/identity/device-auth.json"
rm -f "${OPENCLAW_CONFIG_DIR}/devices/paired.json"
rm -f "${OPENCLAW_CONFIG_DIR}/devices/pending.json"

# Remove stale gateway.auth.token from config so gateway uses current env var
if [[ -f "${OPENCLAW_CONFIG_DIR}/openclaw.json" ]]; then
  python3 -c "
import json, sys
p = sys.argv[1]
try:
    c = json.load(open(p))
    a = c.get('gateway', {}).get('auth', {})
    if 'token' in a:
        del a['token']
        if not a: c.get('gateway', {}).pop('auth', None)
        out = json.dumps(c, indent=2) + '\n'
        open(p, 'w').write(out)
except: pass
" "${OPENCLAW_CONFIG_DIR}/openclaw.json" 2>/dev/null || true
fi

ONBOARD_EXIT=0
docker compose "${COMPOSE_ARGS[@]}" run --rm openclaw-cli onboard --no-install-daemon || ONBOARD_EXIT=$?

if [[ $ONBOARD_EXIT -ne 0 ]]; then
  echo ""
  echo "==> Onboard could not complete device pairing (non-loopback network)."
  echo "    Auto-approving..."
  # The stale pending request has silent=false (from Docker bridge).
  # requestDevicePairing() won't update silent on existing requests,
  # so we must delete it and let a loopback connection create a fresh one.
  rm -f "${OPENCLAW_CONFIG_DIR}/devices/pending.json"
  sleep 1
  # Run from inside the gateway container → loopback → silent=true → auto-approved.
  docker compose "${COMPOSE_ARGS[@]}" exec -T openclaw-gateway \
    node dist/index.js devices list \
    --url ws://127.0.0.1:18789 \
    --token "$OPENCLAW_GATEWAY_TOKEN" \
    --json >/dev/null 2>&1 || true
fi

echo ""
echo "==> Provider setup (optional)"
echo "WhatsApp (QR):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels login"
echo "Telegram (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels add --channel telegram --token <token>"
echo "Discord (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli channels add --channel discord --token <token>"
echo "Docs: https://docs.openclaw.ai/channels"

echo ""
echo "==> Starting gateway"
docker compose "${COMPOSE_ARGS[@]}" up -d openclaw-gateway

echo ""
echo "Gateway running with host port mapping."
echo "Access from tailnet devices via the host's tailnet IP."
echo "Config: $OPENCLAW_CONFIG_DIR"
echo "Workspace: $OPENCLAW_WORKSPACE_DIR"
echo "Token: $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Commands:"
echo "  ${COMPOSE_HINT} logs -f openclaw-gateway"
echo "  ${COMPOSE_HINT} exec openclaw-gateway ./openclaw health --token \"$OPENCLAW_GATEWAY_TOKEN\""
