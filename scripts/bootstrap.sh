#!/usr/bin/env bash
# ==============================================================================
# bootstrap.sh — Zydra Multi-Agent | OpenClaw Gateway Entrypoint
# Schema source: official openclaw/openclaw docs + production config examples
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
# 2. VALIDATE — fail fast, no silent broken starts
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
# 5. GENERATE CONFIG (schema-validated structure)
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "🏗️  Fresh install — generating Zydra config..."

  # Token: preserve existing if passed via env, otherwise generate
  TOKEN="${OPENCLAW_TOKEN:-$(openssl rand -hex 24 2>/dev/null \
    || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")}"

  # Build allowedOrigins — no empty strings
  ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
  [ -n "${BASE_URL:-}" ] && ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"${BASE_URL}\""
  [ -n "${SERVICE_FQDN_OPENCLAW:-}" ] && \
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"https://${SERVICE_FQDN_OPENCLAW}\""

  # Telegram enabled only if token is set
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

  cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "port": ${OPENCLAW_GATEWAY_PORT},
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
          { "id": "meta/llama-3.3-70b-instruct", "contextWindow": 128000, "maxTokens": 4096 },
          { "id": "meta/llama-3.1-70b-instruct", "contextWindow": 128000, "maxTokens": 4096 },
          { "id": "meta/llama-3.1-8b-instruct",  "contextWindow": 128000, "maxTokens": 4096 }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "${WORKSPACE_DIR}",
      "model": {
        "primary": "openai/meta/llama-3.1-70b-instruct",
        "fallbacks": ["openai/meta/llama-3.1-8b-instruct"]
      }
    },
    "list": [
      {
        "id": "zydra-ops",
        "name": "Zydra Ops",
        "default": true,
        "model": { "primary": "openai/meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Ops, the master orchestrator. Route requests to: zydra-pa (schedule/calendar), zydra-sales (leads from n8n), zydra-email (email outreach), zydra-growth (coaching/skill tracking). For multi-step tasks coordinate the sequence. Always confirm what you are routing and why. Be decisive."
      },
      {
        "id": "zydra-pa",
        "name": "Zydra PA",
        "model": { "primary": "openai/meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra PA, a sharp personal assistant. Create, read, update, and delete calendar events. Always confirm time, date, and timezone before acting. Never assume AM/PM. Summarize the schedule on request."
      },
      {
        "id": "zydra-sales",
        "name": "Zydra Sales",
        "model": { "primary": "openai/meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Sales. Process raw lead data from n8n. For each lead: score High/Medium/Low with one-line reason, extract contact/budget/timeline/fit score 1-10, recommend single best next action. Output a clean ranked list. Flag dead leads immediately."
      },
      {
        "id": "zydra-email",
        "name": "Zydra Email",
        "model": { "primary": "openai/meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra Email. Two personas: (1) Job Candidate — formal, achievement-focused, candidate email account. (2) Marketing — persuasive, value-driven, marketing email account. Always confirm persona before drafting. Show full draft and get approval before sending. Never mix accounts."
      },
      {
        "id": "zydra-growth",
        "name": "Zydra Growth",
        "model": { "primary": "openai/meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra Growth, a demanding personal development coach. Track daily learning, skills, and goals. Maintain a running log. Proactively check in via Telegram. Create weekly plans based on what was actually done. Ask hard questions when progress stalls. Give concrete next steps only."
      }
    ]
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_ENABLED},
      "botToken": "${TELEGRAM_BOT_TOKEN:-}",
      "dmPolicy": "pairing",
      "streamMode": "partial"
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
EOF

  chmod 600 "$CONFIG_FILE"
  echo "✅ Config written to $CONFIG_FILE"
  echo "🔑 Token: $TOKEN"

else
  echo "✅ Config exists at $CONFIG_FILE — skipping generation"
fi

# ------------------------------------------------------------------------------
# 6. READ TOKEN FOR BANNER
# ------------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)
fi

[ -z "$TOKEN" ] && echo "⚠️  WARNING: Could not read token from config."

# ------------------------------------------------------------------------------
# 7. SEED WORKSPACE
# ------------------------------------------------------------------------------
for seedfile in SOUL.md BOOTSTRAP.md; do
  if [ ! -f "$WORKSPACE_DIR/$seedfile" ] && [ -f "/app/$seedfile" ]; then
    echo "✨ Seeding $seedfile"
    cp "/app/$seedfile" "$WORKSPACE_DIR/$seedfile"
  fi
done

# ------------------------------------------------------------------------------
# 8. SANDBOX
# ------------------------------------------------------------------------------
if [ "${SANDBOX_CONTAINER:-false}" = "true" ]; then
  [ -f /app/scripts/sandbox-setup.sh ]         && bash /app/scripts/sandbox-setup.sh
  [ -f /app/scripts/sandbox-browser-setup.sh ] && bash /app/scripts/sandbox-browser-setup.sh
fi

# ------------------------------------------------------------------------------
# 9. RECOVERY MONITOR
# ------------------------------------------------------------------------------
if [ -f /app/scripts/recover_sandbox.sh ]; then
  cp /app/scripts/recover_sandbox.sh  "$WORKSPACE_DIR/"
  cp /app/scripts/monitor_sandbox.sh  "$WORKSPACE_DIR/"
  chmod +x "$WORKSPACE_DIR/recover_sandbox.sh" "$WORKSPACE_DIR/monitor_sandbox.sh"
  bash "$WORKSPACE_DIR/recover_sandbox.sh"
  nohup bash "$WORKSPACE_DIR/monitor_sandbox.sh" > /dev/null 2>&1 &
fi

# ------------------------------------------------------------------------------
# 10. LIMITS + BANNER
# ------------------------------------------------------------------------------
ulimit -n 65535

echo ""
echo "=================================================================="
echo "🦞 Zydra / OpenClaw is starting!"
echo "=================================================================="
echo "🔑 Token     : $TOKEN"
echo "🌍 Local URL : http://localhost:${OPENCLAW_GATEWAY_PORT}?token=${TOKEN}"
[ -n "${SERVICE_FQDN_OPENCLAW:-}" ] && \
  echo "☁️  Public URL : https://${SERVICE_FQDN_OPENCLAW}?token=${TOKEN}"
echo ""
echo "👉 To pair: bash /app/scripts/openclaw-approve.sh"
echo "🔧 ulimit  : $(ulimit -n)"
echo "=================================================================="
echo ""

# ------------------------------------------------------------------------------
# 11. LAUNCH
# ------------------------------------------------------------------------------
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
