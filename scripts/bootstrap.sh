#!/usr/bin/env bash
# ==============================================================================
# bootstrap.sh — OpenClaw / Zydra Startup Entrypoint
# Idempotent: safe to run multiple times.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 0. MIGRATION (one-time, from old /root paths to /data)
# ------------------------------------------------------------------------------
if [ -f "/app/scripts/migrate-to-data.sh" ]; then
  bash "/app/scripts/migrate-to-data.sh"
fi

# ------------------------------------------------------------------------------
# 1. RESOLVE PATHS
# ------------------------------------------------------------------------------
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"

# ------------------------------------------------------------------------------
# 2. VALIDATE REQUIRED ENV VARS BEFORE ANYTHING ELSE
# FIXED: was missing — empty API key causes silent 401s after startup
# ------------------------------------------------------------------------------
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is not set. Cannot start without LLM credentials."
  exit 1
fi

if [ -z "${BASE_URL:-}" ] && [ -z "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  echo "⚠️  WARNING: Neither BASE_URL nor SERVICE_FQDN_OPENCLAW is set."
  echo "    allowedOrigins will only include localhost. UI may fail from public URL."
fi

# ------------------------------------------------------------------------------
# 3. CREATE DIRECTORY STRUCTURE
# ------------------------------------------------------------------------------
mkdir -p "$OPENCLAW_STATE"
mkdir -p "$OPENCLAW_STATE/credentials"
mkdir -p "$OPENCLAW_STATE/agents/main/sessions"
mkdir -p "$OPENCLAW_STATE/state"
mkdir -p "$WORKSPACE_DIR"
chmod 700 "$OPENCLAW_STATE"
chmod 700 "$OPENCLAW_STATE/credentials"

# ------------------------------------------------------------------------------
# 4. SYMLINK /root dotdirs → /data
# ------------------------------------------------------------------------------
for dir in .agents .ssh .config .local .cache .npm .bun .claude .kimi; do
  if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then
    ln -sf "/data/$dir" "/root/$dir"
  fi
done

# ------------------------------------------------------------------------------
# 5. GENERATE CONFIG
# FIXED: model key was "openai/meta/llama-3.1-70b-instruct" — wrong, schema rejects it
# FIXED: allowedOrigins had empty strings when env vars unset
# FIXED: models block had custom keys (zydra-ultra etc) — OpenClaw schema rejects unknown keys
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "🏗️  Fresh install — generating Zydra multi-agent config..."

  TOKEN=$(openssl rand -hex 24 2>/dev/null \
    || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")

  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

  # FIXED: Build allowedOrigins conditionally — no empty strings
  ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""
  if [ -n "${BASE_URL:-}" ]; then
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"${BASE_URL}\""
  fi
  if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS}, \"https://${SERVICE_FQDN_OPENCLAW}\""
  fi

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
  "llm": {
    "provider": "openai",
    "baseUrl": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}",
    "apiKey": "${OPENAI_API_KEY}"
  },
  "agents": {
    "defaults": {
      "workspace": "${WORKSPACE_DIR}",
      "model": {
        "primary": "meta/llama-3.1-70b-instruct"
      }
    },
    "list": [
      {
        "id": "zydra-ops",
        "name": "Zydra Ops",
        "default": true,
        "model": { "primary": "meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Ops, the master orchestrator for a personal AI system called Zydra. You route incoming requests to the correct specialist agent. Specialists: zydra-pa (schedule/calendar), zydra-sales (leads/business data from n8n), zydra-email (email outreach with persona switching), zydra-growth (daily coaching and skill tracking). When a task spans multiple agents, coordinate the sequence. Always confirm what you are routing and why. Be concise. Default to action over explanation."
      },
      {
        "id": "zydra-pa",
        "name": "Zydra PA",
        "model": { "primary": "meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra PA, a sharp personal assistant. You manage the user's schedule: create, read, update, and delete calendar events. You are direct and always confirm the action you took with the exact time, date, and timezone. When given a vague time, ask for clarification before acting. Never assume AM/PM. Summarize the current schedule when asked."
      },
      {
        "id": "zydra-sales",
        "name": "Zydra Sales",
        "model": { "primary": "meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Sales, a senior business development manager. You receive raw lead data from n8n workflows. For each lead, you: (1) Score it High/Medium/Low with a one-line reason, (2) Extract: contact name, budget, timeline, project type, fit score 1-10, (3) Recommend the single best next action. Output as a clean ranked list. Be analytical. No fluff. Flag anything that looks like spam or a dead lead immediately."
      },
      {
        "id": "zydra-email",
        "name": "Zydra Email",
        "model": { "primary": "meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra Email, an email composer and sender with two distinct personas. Persona 1 — Job Candidate: formal, achievement-focused tone, highlights skills and results, uses the candidate email account. Persona 2 — Marketing: persuasive, value-driven, benefit-led tone, uses the marketing email account. ALWAYS confirm which persona the user wants before drafting. NEVER mix tone or accounts. After drafting, show the full email and ask for approval before sending."
      },
      {
        "id": "zydra-growth",
        "name": "Zydra Growth",
        "model": { "primary": "meta/llama-3.1-70b-instruct" },
        "systemPrompt": "You are Zydra Growth, a demanding but supportive personal development coach. You track the user's daily learning, skills practiced, and goals hit. You maintain a running log. You proactively check in at scheduled intervals. You create weekly review plans and adjust them based on what was actually done — not what was planned. When progress stalls, ask hard questions. When goals are hit, acknowledge specifically. Give concrete next steps, never vague advice."
      }
    ]
  },
  "plugins": {
    "enabled": true,
    "entries": {
      "telegram": {
        "enabled": ${TELEGRAM_ENABLED},
        "token": "${TELEGRAM_BOT_TOKEN:-}",
        "defaultAgent": "zydra-ops"
      }
    }
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
# 6. READ TOKEN FROM CONFIG (for banner)
# FIXED: added grep fallback if jq is missing from image
# ------------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)
fi

if [ -z "$TOKEN" ]; then
  echo "⚠️  WARNING: Could not read token from config. Auth may be broken."
fi

# ------------------------------------------------------------------------------
# 7. SEED WORKSPACE FILES
# ------------------------------------------------------------------------------
mkdir -p "$WORKSPACE_DIR"

for seedfile in SOUL.md BOOTSTRAP.md; do
  if [ ! -f "$WORKSPACE_DIR/$seedfile" ] && [ -f "/app/$seedfile" ]; then
    echo "✨ Seeding $seedfile to $WORKSPACE_DIR"
    cp "/app/$seedfile" "$WORKSPACE_DIR/$seedfile"
  fi
done

# ------------------------------------------------------------------------------
# 8. SANDBOX SETUP
# ------------------------------------------------------------------------------
if [ "${SANDBOX_CONTAINER:-false}" = "true" ]; then
  [ -f /app/scripts/sandbox-setup.sh ] && bash /app/scripts/sandbox-setup.sh
  [ -f /app/scripts/sandbox-browser-setup.sh ] && bash /app/scripts/sandbox-browser-setup.sh
fi

# ------------------------------------------------------------------------------
# 9. RECOVERY & HEALTH MONITOR
# ------------------------------------------------------------------------------
if [ -f /app/scripts/recover_sandbox.sh ]; then
  echo "🛡️  Deploying Recovery Protocols..."
  cp /app/scripts/recover_sandbox.sh "$WORKSPACE_DIR/"
  cp /app/scripts/monitor_sandbox.sh "$WORKSPACE_DIR/"
  chmod +x "$WORKSPACE_DIR/recover_sandbox.sh" "$WORKSPACE_DIR/monitor_sandbox.sh"
  bash "$WORKSPACE_DIR/recover_sandbox.sh"
  nohup bash "$WORKSPACE_DIR/monitor_sandbox.sh" > /dev/null 2>&1 &
fi

# ------------------------------------------------------------------------------
# 10. SYSTEM LIMITS
# ------------------------------------------------------------------------------
ulimit -n 65535

# ------------------------------------------------------------------------------
# 11. BANNER
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "🦞 Zydra / OpenClaw is starting!"
echo "=================================================================="
echo "🔑 Token     : $TOKEN"
echo "🌍 Local URL : http://localhost:${OPENCLAW_GATEWAY_PORT}?token=${TOKEN}"
if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  echo "☁️  Public URL : https://${SERVICE_FQDN_OPENCLAW}?token=${TOKEN}"
fi
echo ""
echo "👉 To pair: bash /app/scripts/openclaw-approve.sh"
echo "🔧 ulimit  : $(ulimit -n)"
echo "=================================================================="
echo ""

# ------------------------------------------------------------------------------
# 12. LAUNCH
# ------------------------------------------------------------------------------
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
