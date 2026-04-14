#!/usr/bin/env bash
# ==============================================================================
# bootstrap.sh — Finalized Zydra Orchestrator Entrypoint (Production Ready)
# Purpose: Idempotent initialization for OpenClaw on Coolify VPS.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. PATHS & VALIDATION
# ------------------------------------------------------------------------------
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
OPENCLAW_GATEWAY_PORT="${PORT:-18789}"

# [Bug 3 Fix]: Fatal exit if LLM credentials are missing
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ FATAL: OPENAI_API_KEY is not set. Deployment cannot proceed."
  exit 1
fi

# Create directory structure
mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR"

# ------------------------------------------------------------------------------
# 2. DYNAMIC CORS ORIGINS [Bug 2 Fix]
# ------------------------------------------------------------------------------
# We build the JSON array manually to avoid empty strings or malformed syntax.
ALLOWED_ORIGINS="\"http://localhost:${OPENCLAW_GATEWAY_PORT}\""

if [ -n "${BASE_URL:-}" ]; then
  ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"${BASE_URL}\""
fi

if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
  # Ensure protocol is present
  if [[ ! $SERVICE_FQDN_OPENCLAW == http* ]]; then
    ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"https://${SERVICE_FQDN_OPENCLAW}\""
  else
    ALLOWED_ORIGINS="$ALLOWED_ORIGINS, \"${SERVICE_FQDN_OPENCLAW}\""
  fi
fi

# ------------------------------------------------------------------------------
# 3. GENERATE CONFIG (Idempotent)
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
 echo "🏗️ Fresh install detected — generating Zydra 5-Agent Config..."

 # Generate secure token [cite: 18]
 TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
 
 # Plugin logic
 [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && TELEGRAM_ENABLED="true" || TELEGRAM_ENABLED="false"

 # [Bug 1, 6, 7, 8 Fixes]: Correct Model IDs, Detailed Prompts, and Production Security
 cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "port": $OPENCLAW_GATEWAY_PORT,
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false,
      "allowedOrigins": [$ALLOWED_ORIGINS]
    },
    "auth": { "mode": "token", "token": "$TOKEN" }
  },
  "llm": {
    "provider": "openai",
    "baseUrl": "${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}",
    "apiKey": "${OPENAI_API_KEY}"
  },
  "agents": {
    "defaults": { 
      "workspace": "$WORKSPACE_DIR",
      "model": { "primary": "meta/llama-3.1-70b-instruct" }
    },
    "list": [
      { 
        "id": "zydra-ops", 
        "name": "Zydra Ops", 
        "default": true, 
        "model": { "primary": "meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Ops, the orchestration layer. You decide which specialist agent should handle a request and can trigger n8n workflows via HTTP webhooks. When a task needs multiple agents, coordinate the sequence and explain the routing." 
      },
      { 
        "id": "zydra-pa", 
        "name": "Zydra PA", 
        "systemPrompt": "You are Zydra PA, a sharp personal assistant. You manage schedules, create events, and track tasks. You are direct, brief, and always confirm what action you took in the calendar." 
      },
      { 
        "id": "zydra-sales", 
        "name": "Zydra Sales", 
        "model": { "primary": "meta/llama-3.3-70b-instruct" },
        "systemPrompt": "You are Zydra Sales, a senior lead analyst. You receive raw data from n8n. Your job: score each lead (High/Medium/Low) and produce a clean prioritized list with recommended next actions. Be analytical, not fluffy." 
      },
      { 
        "id": "zydra-email", 
        "name": "Zydra Email", 
        "systemPrompt": "You are Zydra Email. You draft outreach using specific personas: (1) Job Candidate — formal/achievement-focused, or (2) Marketing — persuasive/value-driven. Never mix tones or personas." 
      },
      { 
        "id": "zydra-growth", 
        "name": "Zydra Growth", 
        "systemPrompt": "You are Zydra Growth, a demanding but supportive coach. You track learning progress and goals. Proactively check in with the user via Telegram to ensure they are hitting their weekly milestones." 
      }
    ]
  },
  "plugins": { 
    "enabled": true, 
    "entries": { 
      "telegram": { 
        "enabled": $TELEGRAM_ENABLED, 
        "token": "${TELEGRAM_BOT_TOKEN:-}", 
        "defaultAgent": "zydra-ops" 
      } 
    } 
  }
}
EOF
 chmod 600 "$CONFIG_FILE"
 echo "✅ Config generated successfully."
else
 echo "✨ Config exists — skipping generation."
fi

# ------------------------------------------------------------------------------
# 4. STARTUP TOKEN EXTRACTION [Bug 5 Fix]
# ------------------------------------------------------------------------------
if command -v jq &>/dev/null; then
  TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
else
  TOKEN=$(grep -o '"token":"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4 || true)
fi

# ------------------------------------------------------------------------------
# 5. BANNER [Bug 4 Fix]
# ------------------------------------------------------------------------------
echo "=================================================================="
echo "🦞 Zydra Orchestrator is Active!"
echo "🌍 Public URL: ${BASE_URL:-https://${SERVICE_FQDN_OPENCLAW:-localhost}}"
echo "🔑 Access Token: $TOKEN"
echo "👉 Authorization: Run 'bash /app/scripts/openclaw-approve.sh'"
echo "=================================================================="

export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
