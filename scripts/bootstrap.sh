#!/usr/bin/env bash
# ==============================================================================
# 🦞 MULTI-MODEL MASTER BOOTSTRAP — Zydra Orchestrator
# Logic: Explicit Resource Mapping for 3-Tiered Reasoning
# ==============================================================================
set -euo pipefail

OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
OPENCLAW_GATEWAY_PORT="${PORT:-18789}"

# Sanity Check
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is missing."
  exit 1
fi

mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR"

# 1. ARCHITECTURAL PERSISTENCE (Restore from essamamdani)
for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do 
  if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then 
    ln -sf "/data/$dir" "/root/$dir" 
  fi
done

# 2. DYNAMIC CORS & TRUSTED PROXIES
ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
[ -n "${BASE_URL:-}" ] && ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"${BASE_URL}\""
if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  [[ ! $SERVICE_FQDN_OPENCLAW == http* ]] && ORIGIN="https://${SERVICE_FQDN_OPENCLAW}" || ORIGIN="${SERVICE_FQDN_OPENCLAW}"
  ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"$ORIGIN\""
fi

# ------------------------------------------------------------------------------
# 3. GENERATE MULTI-MODEL CONFIG (Schema-Valid Version)
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
 echo "🏗️ Upgrading Zydra Config while preserving identity..."
 
 # Restore Token from backup
 if [ -f "${CONFIG_FILE}.migration.bak" ]; then
    TOKEN=$(jq -r '.gateway.auth.token' "${CONFIG_FILE}.migration.bak")
 else
    TOKEN=$(openssl rand -hex 24)
 fi

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
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12", "127.0.0.1"],
    "controlUi": { "enabled": true, "allowInsecureAuth": false, "allowedOrigins": [$ALLOWED_ORIGINS] },
    "auth": { "mode": "token", "token": "$TOKEN" }
  },
  "models": {
    "zydra-ultra": { "id": "meta/llama-3.3-70b-instruct", "provider": "openai" },
    "zydra-balanced": { "id": "meta/llama-3.1-70b-instruct", "provider": "openai" },
    "zydra-fast": { "id": "meta/llama-3.1-8b-instruct", "provider": "openai" }
  },
  "agents": {
    "defaults": { 
      "workspace": "$WORKSPACE_DIR",
      "model": "zydra-ultra"
    },
    "list": [
      { "id": "zydra-ops", "name": "Zydra Ops", "default": true, "model": "zydra-ultra" },
      { "id": "zydra-pa", "name": "Zydra PA", "model": "zydra-balanced" },
      { "id": "zydra-sales", "name": "Zydra Sales", "model": "zydra-ultra" },
      { "id": "zydra-email", "name": "Zydra Email", "model": "zydra-fast" },
      { "id": "zydra-growth", "name": "Zydra Growth", "model": "zydra-balanced" }
    ]
  },
  "plugins": { "enabled": true, "entries": { "telegram": { "enabled": true } } }
}
EOF
 chmod 600 "$CONFIG_FILE"
fi

# 4. SEED SOUL & STARTUP
[ -f "/app/SOUL.md" ] && [ ! -f "$WORKSPACE_DIR/SOUL.md" ] && cp "/app/SOUL.md" "$WORKSPACE_DIR/SOUL.md"

if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4 || true)
fi

echo "=================================================================="
echo "🌍 Zydra Orchestrator Live"
echo "🔑 Token: $TOKEN"
echo "👉 Approval: docker exec \$(docker ps -q --filter name=openclaw) bash /app/scripts/openclaw-approve.sh"
echo "=================================================================="

export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
