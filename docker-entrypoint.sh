#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup and config initialization

# Do NOT use set -e - we want to handle errors gracefully
# set -e

echo "[entrypoint] === OpenClaw Render Entrypoint v7 ==="
echo "[entrypoint] Date: $(date)"
echo "[entrypoint] Node: $(node --version 2>&1 || echo 'unknown')"
echo "[entrypoint] Args: $@"

# Setup symlink for persistent storage
if [ -d /data ]; then
  mkdir -p /data/.openclaw
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"

  echo "[entrypoint] Disk usage before cleanup:"
  df -h /data 2>/dev/null || true
  du -sh /data/.openclaw 2>/dev/null || true
  du -sh /data/.openclaw/*/ 2>/dev/null || true

  # Aggressive cleanup to free disk space
  echo "[entrypoint] Running aggressive cleanup..."
  # Remove old logs
  find /data/.openclaw -type f \( -name "*.log" -o -name "*.log.*" \) -delete 2>/dev/null || true
  # Remove old transcripts
  find /data/.openclaw -type f -path "*/transcripts/*" -mtime +3 -delete 2>/dev/null || true
  # Remove old config backups
  find /data/.openclaw -name "openclaw.json.backup*" -delete 2>/dev/null || true
  # Remove old lock files
  find /data/.openclaw -name "*.lock" -delete 2>/dev/null || true
  # Remove browser cache
  rm -rf /data/.openclaw/browser/cache 2>/dev/null || true
  # Remove workspace temp files
  find /data/.openclaw/workspace -type f -name "*.tmp" -delete 2>/dev/null || true
  find /data/.openclaw/workspace -type f -name "*.bak" -delete 2>/dev/null || true
  # Remove completions cache
  rm -rf /data/.openclaw/completions 2>/dev/null || true

  echo "[entrypoint] Disk usage after cleanup:"
  df -h /data 2>/dev/null || true
  du -sh /data/.openclaw 2>/dev/null || true
else
  echo "[entrypoint] WARNING: /data not mounted, using ephemeral storage"
  mkdir -p /home/node/.openclaw
fi

# Setup PATH for skills
if [ -d /data/npm-global/bin ]; then
  export PATH="/data/npm-global/bin:$PATH"
  export NPM_CONFIG_PREFIX=/data/npm-global
  echo "[entrypoint] Added skills to PATH: /data/npm-global/bin"
fi

# Setup Playwright browsers path
if [ -d /home/node/.cache/ms-playwright ]; then
  export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
fi

# ── Clean up stale gateway lock files ────────────────────────────
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
find "$STATE_DIR" -name "gateway.*.lock" -delete 2>/dev/null || true
echo "[entrypoint] Cleaned up stale gateway lock files"

# ── Config initialization ─────────────────────────────────────────
CONFIG_FILE="${STATE_DIR}/openclaw.json"
RESET_MARKER="${STATE_DIR}/.config-reset-v7"

echo "[entrypoint] Config path: $CONFIG_FILE"

# ALWAYS reset config on new marker version
if [ ! -f "$RESET_MARKER" ]; then
  echo "[entrypoint] Config reset triggered (v7)"
  # Don't backup, just delete - saves disk space
  rm -f "$CONFIG_FILE" 2>/dev/null || true
  # Clean up old markers
  rm -f "${STATE_DIR}"/.config-reset-v* 2>/dev/null || true
  touch "$RESET_MARKER" 2>/dev/null || true
fi

# Create minimal seed config if none exists
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[entrypoint] Creating seed config..."
  mkdir -p "$STATE_DIR"
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
  if [ $? -eq 0 ]; then
    echo "[entrypoint] Seed config created successfully"
  else
    echo "[entrypoint] ERROR: Failed to create seed config!"
    echo "[entrypoint] Checking disk space..."
    df -h /data 2>/dev/null || true
    df -i /data 2>/dev/null || true
  fi
else
  echo "[entrypoint] Using existing config"
  # Patch gateway token if needed
  if [ -n "$GATEWAY_TOKEN" ]; then
    node -e "
      const fs = require('fs');
      const p = process.argv[1];
      const t = process.env.OPENCLAW_GATEWAY_TOKEN;
      try {
        const d = JSON.parse(fs.readFileSync(p, 'utf8'));
        let changed = false;
        if (!d.gateway) { d.gateway = {}; changed = true; }
        if (!d.gateway.auth) { d.gateway.auth = {}; changed = true; }
        if (!d.gateway.controlUi) { d.gateway.controlUi = {}; changed = true; }
        if (d.gateway.auth.token !== t) { d.gateway.auth.token = t; changed = true; }
        if (d.gateway.auth.mode !== 'token') { d.gateway.auth.mode = 'token'; changed = true; }
        if (!d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback) {
          d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true; changed = true;
        }
        if (!d.gateway.controlUi.dangerouslyDisableDeviceAuth) {
          d.gateway.controlUi.dangerouslyDisableDeviceAuth = true; changed = true;
        }
        if (changed) {
          fs.writeFileSync(p, JSON.stringify(d, null, 2));
          console.log('[entrypoint] Config patched');
        } else {
          console.log('[entrypoint] Config OK');
        }
      } catch(e) {
        console.error('[entrypoint] Patch error:', e.message);
        const newConfig = {
          gateway: {
            auth: { token: t, mode: 'token' },
            controlUi: { dangerouslyAllowHostHeaderOriginFallback: true, dangerouslyDisableDeviceAuth: true },
            trustedProxies: ['10.0.0.0/8', '172.16.0.0/12']
          }
        };
        fs.writeFileSync(p, JSON.stringify(newConfig, null, 2));
        console.log('[entrypoint] Config recreated');
      }
    " "$CONFIG_FILE" 2>&1
  fi
fi

# Show config (masked)
echo "[entrypoint] Config content:"
cat "$CONFIG_FILE" 2>/dev/null | sed 's/"token": "[^"]*"/"token": "***MASKED***"/g' || echo "[entrypoint] Cannot read config file"

# ── Claude setup-token injection ──────────────────────────────────
CLAUDE_TOKEN="${CLAUDE_SETUP_TOKEN:-}"
if [ -n "$CLAUDE_TOKEN" ]; then
  echo "[entrypoint] Configuring Claude setup-token..."
  AGENT_DIR="${STATE_DIR}/agents/main/agent"
  AUTH_FILE="${AGENT_DIR}/auth-profiles.json"
  mkdir -p "$AGENT_DIR" 2>/dev/null || true

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
    console.log('[entrypoint] Claude setup-token written to: ' + authPath);
  " "$AUTH_FILE" 2>&1 || echo "[entrypoint] WARNING: Failed to write Claude setup-token"
fi

# Start Xvfb if available
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
fi

# ── Test OpenClaw binary before starting ──────────────────────────
echo "[entrypoint] Testing OpenClaw binary..."
node openclaw.mjs --version 2>&1 || echo "[entrypoint] WARNING: version check failed"

# ── Final state dir listing ──────────────────────────────────────
echo "[entrypoint] State dir contents:"
ls -la "$STATE_DIR/" 2>/dev/null || true

echo "[entrypoint] ========================================"
echo "[entrypoint] Starting OpenClaw gateway now..."
echo "[entrypoint] Full command: $@"
echo "[entrypoint] ========================================"

# Use exec to replace shell with OpenClaw process
# Redirect stderr to stdout so Render captures all output
exec "$@" 2>&1
