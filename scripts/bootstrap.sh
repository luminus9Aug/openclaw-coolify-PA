#!/bin/env bash
# ==============================================================================
# bootstrap.sh — Zydra Multi-Agent | OpenClaw Gateway Entrypoint
# FIXED: Added Proxy Trust while preserving Zydra Schema
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. MIGRATION
# ------------------------------------------------------------------------------
if [ -f "/app/scripts/migrate-to-data.sh" ]; then
  bash "/app/scripts/migrate-to-data.sh"
fi

# ------------------------------------------------------------------------------
# 1. PATHS
# ------------------------------------------------------------------------------
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"

# ------------------------------------------------------------------------------
# 1.5 NEW: PROXY DETECTION (For Coolify/Traefik)
# ------------------------------------------------------------------------------
# We use 10.0.0.0/8 as the primary trust for Coolify internal networks
TRAEFIK_IP="10.0.0.0/8"

# ------------------------------------------------------------------------------
# 2. VALIDATE
# ------------------------------------------------------------------------------
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is not set."
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. DIRECTORIES
# ------------------------------------------------------------------------------
mkdir -p "$OPENCLAW_STATE"
mkdir -p "$OPENCLAW_STATE/credentials"
mkdir -p "$OPENCLAW_STATE/agents/main/sessions"
mkdir -p "$OPENCLAW_STATE/state"
mkdir -p "$WORKSPACE_DIR"
chmod 700 "$OPENCLAW_STATE"
chmod 700 "$OPENCLAW_STATE/credentials"

# ------------------------------------------------------------------------------
# 4. SYMLINKS
# ------------------------------------------------------------------------------
for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do
  if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then
    ln -sf "/data/$dir" "/root/$dir"
  fi
done

# ------------------------------------------------------------------------------
# 5. GENERATE CONFIG
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "🏗️  Fresh install — generating Zydra config with Proxy Trust..."

  TOKEN="${OPENCLAW_TOKEN:-$(openssl rand -hex 24 2>/dev/null \
    || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")}"

  ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
  [ -n "${BASE_URL:-}" ] && ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"${BASE_URL}\""
  [ -n "${SERVICE_FQDN_OPENCLAW:-}" ] && \
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"https://${SERVICE_FQDN_OPENCLAW}\""

  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_GATEWAY_PORT},
    "trustedProxies": ["127.0.0.1", "172.16.0.0/12", "192.168.0.0/16"],
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false,
      "allowedOrigins": [${ALLOWED_ORIGINS}]
    },
    "auth": { "mode": "token", "token": "${TOKEN}" }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "openai": {
        "baseUrl": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}",
        "apiKey": "${OPENAI_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "name": "Llama 3.3 70B", "id": "meta/llama-3.3-70b-instruct", "contextWindow": 128000 },
          { "name": "Llama 3.1 8B", "id": "meta/llama-3.1-8b-instruct", "contextWindow": 128000 }
        ]
      }
    }
  },
  "agents": {
    "list": [
      {
        "id": "zydra-ops",
        "name": "Zydra Ops",
        "default": true,
        "model": { "primary": "openai/meta/llama-3.3-70b-instruct" }
      }
    ]
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_ENABLED},
      "botToken": "${TELEGRAM_BOT_TOKEN:-}",
      "streaming": { "mode": "partial", "chunkMode": "length" }
    }
  },
  "meta": {},
  "logging": { "redactSensitive": "tools" }
}
EOF

  chmod 600 "$CONFIG_FILE"
  echo "✅ Config written with trustedProxies."
else
  echo "✅ Config exists — checking for trustedProxies update..."
  # If config exists but no trustedProxies, we inject it via JQ
  if command -v jq &>/dev/null; then
    if ! jq -e '.gateway.trustedProxies' "$CONFIG_FILE" > /dev/null 2>&1; then
       cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
       jq ".gateway.trustedProxies = [\"${TRAEFIK_IP}\", \"127.0.0.1\", \"::1\"]" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
       echo "🔧 Updated existing config with trustedProxies."
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 6. READ TOKEN
# ------------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)
fi

# ------------------------------------------------------------------------------
# 7. SEED WORKSPACE
# ------------------------------------------------------------------------------
for seedfile in SOUL.md BOOTSTRAP.md; do
  if [ ! -f "$WORKSPACE_DIR/$seedfile" ] && [ -f "/app/$seedfile" ]; then
    cp "/app/$seedfile" "$WORKSPACE_DIR/$seedfile"
  fi
done

# ------------------------------------------------------------------------------
# 8. SANDBOX / RECOVERY (Simplified for speed)
# ------------------------------------------------------------------------------
if [ -f /app/scripts/recover_sandbox.sh ]; then
  cp /app/scripts/recover_sandbox.sh /app/scripts/monitor_sandbox.sh "$WORKSPACE_DIR/"
  chmod +x "$WORKSPACE_DIR/recover_sandbox.sh" "$WORKSPACE_DIR/monitor_sandbox.sh"
  bash "$WORKSPACE_DIR/recover_sandbox.sh"
  nohup bash "$WORKSPACE_DIR/monitor_sandbox.sh" > /dev/null 2>&1 &
fi

# ------------------------------------------------------------------------------
# 10. LAUNCH
# ------------------------------------------------------------------------------
ulimit -n 65535
echo "=================================================================="
echo "🦞 Zydra / OpenClaw Started with Trusted Proxies"
echo "=================================================================="
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
