#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup and config initialization

set -e

# Setup symlink for persistent storage
if [ -d /data/.openclaw ]; then
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"
  # Cleanup old logs
  find /data/.openclaw -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +2 -delete 2>/dev/null || true
  find /data/.openclaw -type f -path "*/transcripts/*" -mtime +14 -delete 2>/dev/null || true
fi

# Setup PATH for skills
if [ -d /data/npm-global/bin ]; then
  export PATH="/data/npm-global/bin:$PATH"
  export NPM_CONFIG_PREFIX=/data/npm-global
fi

# Setup Playwright browsers path
if [ -d /home/node/.cache/ms-playwright ]; then
  export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
fi

# ── Config initialization ─────────────────────────────────────────
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
CONFIG_FILE="${STATE_DIR}/openclaw.json"
RESET_MARKER="${STATE_DIR}/.config-reset-v4"

# One-time config reset for version upgrades
if [ -f "$CONFIG_FILE" ] && [ ! -f "$RESET_MARKER" ]; then
  cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
  rm -f "$CONFIG_FILE"
  echo "[entrypoint] Config reset for upgrade (v4)"
  touch "$RESET_MARKER"
fi

# Create minimal seed config if none exists
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$STATE_DIR"
  GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

  # Write a minimal, safe config - only gateway settings needed for Render
  cat > "$CONFIG_FILE" << CONFIGEOF
{
  "gateway": {
    "auth": {
      "token": "${GATEWAY_TOKEN}",
      "mode": "token"
    },
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12"]
  }
}
CONFIGEOF
  echo "[entrypoint] Seed config created"
else
  # Patch existing config: sync gateway token from env
  GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
  if [ -n "$GATEWAY_TOKEN" ]; then
    node -e "
      const fs = require('fs');
      const p = process.argv[1];
      const t = process.env.OPENCLAW_GATEWAY_TOKEN;
      try {
        const d = JSON.parse(fs.readFileSync(p, 'utf8'));
        if (!d.gateway) d.gateway = {};
        if (!d.gateway.auth) d.gateway.auth = {};
        if (!d.gateway.controlUi) d.gateway.controlUi = {};
        d.gateway.auth.token = t;
        d.gateway.auth.mode = 'token';
        d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
        d.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
        if (!d.gateway.trustedProxies) d.gateway.trustedProxies = ['10.0.0.0/8', '172.16.0.0/12'];
        fs.writeFileSync(p, JSON.stringify(d, null, 2));
        console.log('[entrypoint] Config patched');
      } catch(e) {
        console.error('[entrypoint] Patch error:', e.message);
      }
    " "$CONFIG_FILE"
  fi
fi

# ── Claude setup-token injection (auth-profiles.json only) ────────
CLAUDE_TOKEN="${CLAUDE_SETUP_TOKEN:-}"
if [ -n "$CLAUDE_TOKEN" ]; then
  # Write to the default agent's auth-profiles.json
  AGENT_DIR="${STATE_DIR}/agents/main/agent"
  AUTH_FILE="${AGENT_DIR}/auth-profiles.json"
  mkdir -p "$AGENT_DIR"

  node -e "
    const fs = require('fs');
    const authPath = process.argv[1];
    const token = process.env.CLAUDE_SETUP_TOKEN;
    let store = { version: 2, profiles: {} };
    try {
      if (fs.existsSync(authPath)) {
        store = JSON.parse(fs.readFileSync(authPath, 'utf8'));
      }
    } catch(e) {}
    store.profiles = store.profiles || {};
    store.profiles['anthropic:setup-token'] = {
      type: 'token',
      provider: 'anthropic',
      token: token
    };
    fs.writeFileSync(authPath, JSON.stringify(store, null, 2));
    console.log('[entrypoint] Claude setup-token written to auth-profiles.json');
  " "$AUTH_FILE"
fi

# Start Xvfb if available
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
fi

echo "[entrypoint] Starting OpenClaw gateway..."
exec "$@"
