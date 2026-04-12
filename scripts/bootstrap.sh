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

# ------------------------------------------------------------------------------
# 2. CREATE DIRECTORY STRUCTURE
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 4. GENERATE CONFIG — only if it does not already exist
#    This is the core fix: the config is ALWAYS written on a fresh volume,
#    and NEVER overwritten on subsequent restarts (preserving user changes).
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "🏗️  Fresh install detected — generating openclaw.json ..."

    # Generate a cryptographically secure random token
    TOKEN=$(openssl rand -hex 24 2>/dev/null \
        || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")

    # Determine telegram plugin state based on env var
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        TELEGRAM_ENABLED="true"
    else
        TELEGRAM_ENABLED="false"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "commands": {
    "native": true,
    "nativeSkills": true,
    "text": true,
    "bash": true,
    "config": true,
    "debug": true,
    "restart": true,
    "useAccessGroups": true
  },
  "plugins": {
    "enabled": true,
    "entries": {
      "telegram": {
        "enabled": $TELEGRAM_ENABLED
      }
    }
  },
  "skills": {
    "allowBundled": ["*"],
    "install": {
      "nodeManager": "npm"
    }
  },
  "gateway": {
    "port": $OPENCLAW_GATEWAY_PORT,
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": false
    },
    "trustedProxies": ["*"],
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    },
    "auth": {
      "mode": "token",
      "token": "$TOKEN"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE_DIR",
      "envelopeTimestamp": "on",
      "envelopeElapsed": "on",
      "cliBackends": {},
      "heartbeat": {
        "every": "1h"
      },
      "maxConcurrent": 4,
      "sandbox": {
        "mode": "non-main",
        "scope": "session",
        "browser": {
          "enabled": false
        }
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "default",
        "workspace": "$WORKSPACE_DIR"
      }
    ]
  }
}
EOF

    chmod 600 "$CONFIG_FILE"
    echo "✅ Config written to $CONFIG_FILE"
    echo "🔑 Generated token: $TOKEN"
else
    echo "✅ Config already exists at $CONFIG_FILE — skipping generation"
fi

# ------------------------------------------------------------------------------
# 5. READ TOKEN FROM CONFIG (needed for banner, whether new or existing)
# ------------------------------------------------------------------------------
TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)

if [ -z "$TOKEN" ]; then
    echo "⚠️  WARNING: Could not read token from config. Auth may be broken."
fi

# ------------------------------------------------------------------------------
# 6. SEED AGENT WORKSPACE (SOUL.md + BOOTSTRAP.md)
#    Never overwrites if files already exist.
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 7. SANDBOX SETUP (only when running as an actual sandbox container)
# ------------------------------------------------------------------------------
if [ "${SANDBOX_CONTAINER:-false}" = "true" ]; then
    [ -f /app/scripts/sandbox-setup.sh ] && bash /app/scripts/sandbox-setup.sh
    [ -f /app/scripts/sandbox-browser-setup.sh ] && bash /app/scripts/sandbox-browser-setup.sh
fi

# ------------------------------------------------------------------------------
# 8. RECOVERY & HEALTH MONITOR
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
# 9. SYSTEM LIMITS
# ------------------------------------------------------------------------------
ulimit -n 65535

# ------------------------------------------------------------------------------
# 10. BANNER
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "🦞 OpenClaw is starting!"
echo "=================================================================="
echo ""
echo "🔑 Access Token : $TOKEN"
echo ""
echo "🌍 Local URL    : http://localhost:${OPENCLAW_GATEWAY_PORT}?token=${TOKEN}"
if [ -n "${SERVICE_FQDN_OPENCLAW:-}" ]; then
    echo "☁️  Public URL   : https://${SERVICE_FQDN_OPENCLAW}?token=${TOKEN}"
fi
echo ""
echo "👉 Next steps:"
echo "   1. Open the URL above."
echo "   2. Run 'openclaw-approve' in the container terminal to pair."
echo "   3. Run 'openclaw onboard' to configure your agent."
echo ""
echo "🔧 ulimit: $(ulimit -n)"
echo "=================================================================="
echo ""

# ------------------------------------------------------------------------------
# 11. EXPORT STATE DIR AND LAUNCH
# ------------------------------------------------------------------------------
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"
exec openclaw gateway run
