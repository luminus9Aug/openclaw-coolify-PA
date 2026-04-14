#!/usr/bin/env bash
set -euo pipefail

# 1. PATHS
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
OPENCLAW_GATEWAY_PORT="${PORT:-18789}"

# Fatal check
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is not set."
  exit 1
fi

mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR"

# 2. RESOLVE DYNAMIC CORS ORIGINS
ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
if [ -n "${BASE_URL:-}" ]; then
  ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"${BASE_URL}\""
fi
if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"https://${SERVICE_FQDN_OPENCLAW}\""
fi

# 3. GENERATE SCHEMA-VALID CONFIG
if [ ! -f "$CONFIG_FILE" ]; then
 echo "🏗️ Generating Valid Zydra Config..."
 TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
 [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

 # VALIDATED SCHEMA: LLM moved to 'env', 'systemPrompt' removed from agent list
 cat > "$CONFIG_FILE" <<EOF
{
  "env": {
    "OPENAI_API_KEY": "${OPENAI_API_KEY}",
    "OPENAI_BASE_URL": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}"
  },
  "gateway": {
    "port": $OPENCLAW_GATEWAY_PORT,
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
  "plugins": { 
    "enabled": true, 
    "entries": { 
      "telegram": { "enabled": $TELEGRAM_ENABLED } 
    } 
  }
}
EOF
 chmod 600 "$CONFIG_FILE"
fi

# 4. STARTUP
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
