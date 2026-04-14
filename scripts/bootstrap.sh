#!/usr/bin/env bash

# ==============================================================================

# bootstrap.sh — OpenClaw Startup Entrypoint

# Runs every time the container starts.

# Idempotent: safe to run multiple times — never overwrites existing config/data.

# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------

# 0. MIGRATION (one-time, from old /root paths to /data)

# ------------------------------------------------------------------------------

if [ -f "/app/scripts/migrate-to-data.sh" ]; then

bash "/app/scripts/migrate-to-data.sh"

fi

# ------------------------------------------------------------------------------

# 1. RESOLVE PATHS FROM ENVIRONMENT (with safe defaults)

# ------------------------------------------------------------------------------

OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"

CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"

WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"

# ==============================================================================
# NEW: Detect Traefik proxy IP for trustedProxies configuration
# ==============================================================================
# This is critical when OpenClaw runs behind a reverse proxy (Traefik, nginx, etc.)
# Without trustedProxies, the Gateway treats proxy headers as untrusted, causing
# WebSocket connection issues and Dashboard UI freezes.

detect_traefik_ip() {
  # Try multiple detection methods in order of reliability
  
  # Method 1: Direct Docker inspect of Traefik container (most reliable)
  if command -v docker &> /dev/null; then
    local traefik_ip
    traefik_ip=$(docker inspect coolify-proxy --format='{{index .NetworkSettings.Networks "bridge" .IPAddress}}' 2>/dev/null) || true
    if [ -n "$traefik_ip" ]; then
      echo "$traefik_ip"
      return 0
    fi
  fi
  
  # Method 2: Check Docker compose network if we're in a compose context
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ] && command -v docker &> /dev/null; then
    local compose_network="$(docker network ls --filter name="${COMPOSE_PROJECT_NAME}" --format '{{.Name}}' 2>/dev/null | head -1)" || true
    if [ -n "$compose_network" ]; then
      local traefik_ip
      traefik_ip=$(docker inspect coolify-proxy --format="{{index .NetworkSettings.Networks \"$compose_network\" .IPAddress}}" 2>/dev/null) || true
      if [ -n "$traefik_ip" ]; then
        echo "$traefik_ip"
        return 0
      fi
    fi
  fi
  
  # Method 3: Environment variable fallback (allow manual override)
  if [ -n "${TRAEFIK_IP:-}" ]; then
    echo "$TRAEFIK_IP"
    return 0
  fi
  
  # Method 4: Default Docker bridge IP (most common subnet)
  # This is a safe default if Docker is using the standard bridge network
  echo "172.18.0.2"
}

TRAEFIK_IP=$(detect_traefik_ip)

echo "🌐 Detected Traefik/Proxy IP: $TRAEFIK_IP"

# Additional trusted proxy IPs for comprehensive proxy support
# These should be added alongside the Traefik IP
ADDITIONAL_TRUSTED_PROXIES="${ADDITIONAL_TRUSTED_PROXIES:-127.0.0.1,::1}"

# ==============================================================================

# 2. CREATE DIRECTORY STRUCTURE

# ==============================================================================

mkdir -p "$OPENCLAW_STATE"

mkdir -p "$OPENCLAW_STATE/credentials"

mkdir -p "$OPENCLAW_STATE/agents/main/sessions"

mkdir -p "$OPENCLAW_STATE/state"

mkdir -p "$WORKSPACE_DIR"

chmod 700 "$OPENCLAW_STATE"

chmod 700 "$OPENCLAW_STATE/credentials"

# ------------------------------------------------------------------------------

# 3. SYMLINK /root dotdirs → /data (so agent tools persist across restarts)

# ------------------------------------------------------------------------------

for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do

if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then

ln -sf "/data/$dir" "/root/$dir"

fi

done

# ==============================================================================

# 4. GENERATE CONFIG — Updated for Zydra Multi-Agent + NVIDIA NIM + Traefik Support

# ==============================================================================

if [ ! -f "$CONFIG_FILE" ]; then

echo "🏗️ Fresh install detected — generating Zydra multi-agent config with proxy trust..."

TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")

# Determine telegram plugin state

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "port": $OPENCLAW_GATEWAY_PORT,
    "host": "0.0.0.0",
    "trustedProxies": [
     "$TRAEFIK_IP",
      "127.0.0.1",
      "::1",
      "10.0.0.0/8"
    ],
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "allowedOrigins": ["http://localhost:18789", "${BASE_URL:-}", "https://${SERVICE_FQDN_OPENCLAW:-}"]
    },
    "auth": { "mode": "token", "token": "$TOKEN" }
  },
  "llm": {
    "provider": "openai",
    "baseUrl": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}",
    "apiKey": "${OPENAI_API_KEY:-}"
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE_DIR",
      "model": { "primary": "openai/meta/llama-3.1-70b-instruct" }
    },
    "list": [
      { "id": "zydra-ops", "name": "Zydra Ops", "default": true, "systemPrompt": "You are the Zydra Orchestrator. Route tasks to specialized sub-agents." },
      { "id": "zydra-pa", "name": "Zydra PA", "systemPrompt": "You manage the user's personal schedule and calendar." },
      { "id": "zydra-sales", "name": "Zydra Sales", "systemPrompt": "You score leads and process business data from n8n." },
      { "id": "zydra-email", "name": "Zydra Email", "systemPrompt": "You handle candidate and marketing email outreach." },
      { "id": "zydra-growth", "name": "Zydra Growth", "systemPrompt": "You are a daily coach tracking user goals and progress." }
    ]
  },
  "plugins": {
    "enabled": true,
    "entries": {
      "telegram": { "enabled": $TELEGRAM_ENABLED, "token": "${TELEGRAM_BOT_TOKEN:-}", "defaultAgent": "zydra-ops" }
    }
  }
}
EOF

chmod 600 "$CONFIG_FILE"

echo "✅ Config written to $CONFIG_FILE"
echo "🌐 Gateway trustedProxies set to: [$TRAEFIK_IP, $ADDITIONAL_TRUSTED_PROXIES]"
echo "🔑 Generated token: $TOKEN"

else

echo "✅ Config already exists at $CONFIG_FILE — skipping generation"

# ========================================================================
# UPDATE EXISTING CONFIG WITH trustedProxies IF MISSING
# ========================================================================
# This ensures even existing configs get the proxy fix on container restart

if ! jq -e '.gateway.trustedProxies' "$CONFIG_FILE" > /dev/null 2>&1; then
  echo "⚠️  WARNING: Existing config missing gateway.trustedProxies"
  echo "🔧 Adding trustedProxies to existing config..."
  
  # Backup existing config
  cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%s)"
  
  # Add trustedProxies using jq
  jq ".gateway.trustedProxies = [\"$TRAEFIK_IP\", \"127.0.0.1\", \"::1\"]" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  
  echo "✅ trustedProxies added successfully"
  echo "💾 Backup saved to: $CONFIG_FILE.backup.*"
else
  echo "✅ gateway.trustedProxies already configured in existing config"
  
  # Optional: Log current trustedProxies value
  current_proxies=$(jq -r '.gateway.trustedProxies | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
  echo "📋 Current trustedProxies: [$current_proxies]"
fi

fi

# ==============================================================================

# 5. READ TOKEN FROM CONFIG (needed for banner, whether new or existing)

# ==============================================================================

TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)

if [ -z "$TOKEN" ]; then

echo "⚠️ WARNING: Could not read token from config. Auth may be broken."

fi

# ==============================================================================

# 6. SEED AGENT WORKSPACE (SOUL.md + BOOTSTRAP.md)

# Never overwrites if files already exist.

# ==============================================================================

mkdir -p "$WORKSPACE_DIR"

if [ -f "$WORKSPACE_DIR/SOUL.md" ]; then

echo "🧠 SOUL.md already exists — skipping"

else

if [ -f "/app/SOUL.md" ]; then

echo "✨ Seeding SOUL.md to $WORKSPACE_DIR"

cp "/app/SOUL.md" "$WORKSPACE_DIR/SOUL.md"

fi

fi

if [ -f "$WORKSPACE_DIR/BOOTSTRAP.md" ]; then

echo "📖 BOOTSTRAP.md already exists — skipping"

else

if [ -f "/app/BOOTSTRAP.md" ]; then

echo "🚀 Seeding BOOTSTRAP.md to $WORKSPACE_DIR"

cp "/app/BOOTSTRAP.md" "$WORKSPACE_DIR/BOOTSTRAP.md"

fi

fi

# ==============================================================================

# 7. SANDBOX SETUP (only when running as an actual sandbox container)

# ==============================================================================

if [ "${SANDBOX_CONTAINER:-false}" = "true" ]; then

[ -f /app/scripts/sandbox-setup.sh ] && bash /app/scripts/sandbox-setup.sh

[ -f /app/scripts/sandbox-browser-setup.sh ] && bash /app/scripts/sandbox-browser-setup.sh

fi

# ==============================================================================

# 8. RECOVERY & HEALTH MONITOR

# ==============================================================================

if [ -f /app/scripts/recover_sandbox.sh ]; then

echo "🛡️ Deploying Recovery Protocols..."

cp /app/scripts/recover_sandbox.sh "$WORKSPACE_DIR/"

cp /app/scripts/monitor_sandbox.sh "$WORKSPACE_DIR/"

chmod +x "$WORKSPACE_DIR/recover_sandbox.sh" "$WORKSPACE_DIR/monitor_sandbox.sh"

bash "$WORKSPACE_DIR/recover_sandbox.sh"

nohup bash "$WORKSPACE_DIR/monitor_sandbox.sh" > /dev/null 2>&1 &

fi

# ==============================================================================

# 9. SYSTEM LIMITS

# ==============================================================================

ulimit -n 65535

# ==============================================================================

# 10. BANNER

# ==============================================================================

echo ""

echo "=================================================================="

echo "🦞 OpenClaw is starting!"

echo "=================================================================="

echo ""

echo "🔑 Access Token : $TOKEN"

echo ""

echo "🌍 Local URL : http://localhost:${OPENCLAW_GATEWAY_PORT}?token=${TOKEN}"

if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then

echo "☁️ Public URL : https://${SERVICE_FQDN_OPENCLAW}?token=${TOKEN}"

fi

echo ""

echo "🌐 Gateway Configuration:"

echo "   - Port: $OPENCLAW_GATEWAY_PORT"

echo "   - Trusted Proxies: [$TRAEFIK_IP, $ADDITIONAL_TRUSTED_PROXIES]"

echo "   - Control UI: http://localhost:$OPENCLAW_GATEWAY_PORT"

echo ""

echo "👉 Next steps:"

echo " 1. Open the URL above."

echo " 2. Run 'openclaw-approve' in the container terminal to pair."

echo " 3. Run 'openclaw onboard' to configure your agent."

echo ""

echo "🔧 ulimit: $(ulimit -n)"

echo "📊 Dashboard: If you see 'infinite spinner' or UI freeze, verify trustedProxies"

echo "=================================================================="

echo ""

# ==============================================================================

# 11. EXPORT STATE DIR AND LAUNCH

# ==============================================================================

export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"

exec openclaw gateway run
