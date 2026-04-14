#!/usr/bin/env bash
# ==============================================================================
# 🦞 MASTER BOOTSTRAP — Zydra Orchestrator (Optimized for Coolify)
# Validated against essamamdani/openclaw-coolify + Zydra Stability Schema
# ==============================================================================
set -euo pipefail

# 1. CORE PATHS & VALIDATION
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
OPENCLAW_GATEWAY_PORT="${PORT:-18789}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is not set."
  exit 1
fi

mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR"

# 2. PERSISTENCE GLUE (Restored from essamamdani)
# This ensures agent tools, SSH keys, and node modules survive a redeploy.
for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do 
  if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then 
    ln -sf "/data/$dir" "/root/$dir" 
  fi
done

# 3. DYNAMIC CORS RESOLUTION (Zydra Stability Fix)
ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
[ -n "${BASE_URL:-}" ] && ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"${BASE_URL}\""
if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  [[ ! $SERVICE_FQDN_OPENCLAW == http* ]] && ORIGIN="https://${SERVICE_FQDN_OPENCLAW}" || ORIGIN="${SERVICE_FQDN_OPENCLAW}"
  ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"$ORIGIN\""
fi

# ------------------------------------------------------------------------------
# 4. GENERATE SCHEMA-VALID CONFIG (Zydra Stability Fix v2)
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
 echo "🏗️ Generating Valid Zydra Config..."
 TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
 [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

 # VALIDATED SCHEMA: Added 'mode' and 'bind' to gateway to prevent startup block
 cat > "$CONFIG_FILE" <<EOF
{
  "env": {
    "OPENAI_API_KEY": "${OPENAI_API_KEY}",
    "OPENAI_BASE_URL": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}"
  },
  "gateway": {
    "port": $OPENCLAW_GATEWAY_PORT,
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false,
      "allowedOrigins": [$ALLOWED_ORIGINS]
    },
    "auth": { "mode": "token", "token": "$TOKEN" }
  },
  "agents": {
    "defaults": { 
      "workspace": "$WORKSPACE_DIR",
      "model": { "primary": "meta/llama-3.1-70b-instruct" }
    },
    "list": [
      { "id": "zydra-ops", "name": "Zydra Ops", "default": true, "workspace": "$WORKSPACE_DIR" },
      { "id": "zydra-pa", "name": "Zydra PA", "workspace": "$WORKSPACE_DIR" },
      { "id": "zydra-sales", "name": "Zydra Sales", "workspace": "$WORKSPACE_DIR" },
      { "id": "zydra-email", "name": "Zydra Email", "workspace": "$WORKSPACE_DIR" },
      { "id": "zydra-growth", "name": "Zydra Growth", "workspace": "$WORKSPACE_DIR" }
    ]
  },
  "plugins": { "enabled": true, "entries": { "telegram": { "enabled": $TELEGRAM_ENABLED } } }
}
EOF
 chmod 600 "$CONFIG_FILE"
fi

# 5. SEED WORKSPACE PROTOCOLS (Restored from essamamdani)
# This seeds your SOUL.md which contains your agents' deep personas.
if [ -f "/app/SOUL.md" ] && [ ! -f "$WORKSPACE_DIR/SOUL.md" ]; then
  cp "/app/SOUL.md" "$WORKSPACE_DIR/SOUL.md"
fi

# 6. SANDBOX & RECOVERY (Restored from essamamdani)
if [ -f /app/scripts/recover_sandbox.sh ]; then
  echo "🛡️ Deploying Self-Healing Protocols..."
  cp /app/scripts/recover_sandbox.sh "$WORKSPACE_DIR/"
  nohup bash "$WORKSPACE_DIR/recover_sandbox.sh" > /dev/null 2>&1 &
fi

# 7. BANNER & LAUNCH
if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4 || true)
fi

echo "=================================================================="
echo "🌍 URL: ${BASE_URL:-https://${SERVICE_FQDN_OPENCLAW:-localhost}}"
echo "🔑 Token: $TOKEN"
echo "👉 Run: bash /app/scripts/openclaw-approve.sh"
echo "=================================================================="

export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
