#!/bin/sh
# OpenClaw Render Entrypoint v8
# ALWAYS regenerates seed config to prevent corrupted config issues

echo "[entrypoint] === OpenClaw Render Entrypoint v8 ==="
echo "[entrypoint] Date: $(date)"
echo "[entrypoint] Node: $(node --version 2>&1 || echo unknown)"
echo "[entrypoint] CMD: $@"

# ── Persistent storage setup ────────────────────────────────────
if [ -d /data ]; then
  mkdir -p /data/.openclaw
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked: /data/.openclaw -> /home/node/.openclaw"
else
  echo "[entrypoint] WARNING: /data not mounted"
  mkdir -p /home/node/.openclaw
fi

# ── PATH setup ──────────────────────────────────────────────────
if [ -d /data/npm-global/bin ]; then
  export PATH="/data/npm-global/bin:$PATH"
  export NPM_CONFIG_PREFIX=/data/npm-global
fi

# ── Playwright ──────────────────────────────────────────────────
if [ -d /home/node/.cache/ms-playwright ]; then
  export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
fi

# ── Clean up lock files ─────────────────────────────────────────
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
find "$STATE_DIR" -name "gateway.*.lock" -delete 2>/dev/null || true
find "$STATE_DIR" -name "*.lock" -delete 2>/dev/null || true

# ── Disk cleanup ────────────────────────────────────────────────
find "$STATE_DIR" -name "openclaw.json.backup*" -delete 2>/dev/null || true
find "$STATE_DIR" -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +1 -delete 2>/dev/null || true
find "$STATE_DIR" -type f -path "*/transcripts/*" -mtime +3 -delete 2>/dev/null || true
rm -rf "$STATE_DIR/completions" 2>/dev/null || true

echo "[entrypoint] Disk: $(df -h /data 2>/dev/null | tail -1 || echo 'N/A')"

# ── ALWAYS regenerate seed config ───────────────────────────────
# This prevents corrupted config from crashing OpenClaw
CONFIG_FILE="${STATE_DIR}/openclaw.json"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

echo "[entrypoint] Regenerating seed config..."
rm -f "$CONFIG_FILE" 2>/dev/null || true

cat > "$CONFIG_FILE" << 'CONFIGEOF'
{
  "gateway": {
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12"]
  }
}
CONFIGEOF

# Inject gateway token via node (handles JSON properly)
if [ -n "$GATEWAY_TOKEN" ]; then
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const t = process.env.OPENCLAW_GATEWAY_TOKEN;
    try {
      const d = JSON.parse(fs.readFileSync(p, 'utf8'));
      d.gateway.auth = { token: t, mode: 'token' };
      fs.writeFileSync(p, JSON.stringify(d, null, 2));
      console.log('[entrypoint] Gateway token set: ' + t.substring(0, 12) + '...');
    } catch(e) {
      console.error('[entrypoint] Token inject error: ' + e.message);
    }
  " "$CONFIG_FILE" 2>&1
fi

echo "[entrypoint] Config written:"
cat "$CONFIG_FILE" 2>/dev/null | sed 's/"token": "[^"]*"/"token": "***"/g' || echo "[entrypoint] Cannot read config"

# ── Claude setup-token ──────────────────────────────────────────
CLAUDE_TOKEN="${CLAUDE_SETUP_TOKEN:-}"
if [ -n "$CLAUDE_TOKEN" ]; then
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
    console.log('[entrypoint] Claude token -> ' + authPath);
  " "$AUTH_FILE" 2>&1 || echo "[entrypoint] WARNING: Claude token write failed"
fi

# ── Xvfb ────────────────────────────────────────────────────────
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
fi

# ── Start OpenClaw ──────────────────────────────────────────────
echo "[entrypoint] ========================================"
echo "[entrypoint] Starting: $@"
echo "[entrypoint] ========================================"
exec "$@" 2>&1
