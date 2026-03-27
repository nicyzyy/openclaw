#!/bin/sh
# OpenClaw Render Entrypoint v9 - Minimal startup to diagnose issues
# All output goes to stdout/stderr for Render log capture

printf "[entrypoint-v9] STARTING at %s\n" "$(date)" >&2
printf "[entrypoint-v9] STARTING at %s\n" "$(date)"
printf "[entrypoint-v9] whoami=%s uid=%s\n" "$(whoami)" "$(id -u)"
printf "[entrypoint-v9] pwd=%s\n" "$(pwd)"
printf "[entrypoint-v9] CMD=%s\n" "$*"

# ── Persistent storage setup ────────────────────────────────────
if [ -d /data ]; then
  printf "[entrypoint-v9] /data exists\n"
  mkdir -p /data/.openclaw 2>&1 || printf "[entrypoint-v9] WARN: cannot mkdir /data/.openclaw\n"
  rm -rf /home/node/.openclaw 2>/dev/null
  ln -sf /data/.openclaw /home/node/.openclaw 2>&1 || printf "[entrypoint-v9] WARN: cannot symlink\n"
  printf "[entrypoint-v9] Linked /data/.openclaw -> /home/node/.openclaw\n"
  df -h /data 2>/dev/null || true
else
  printf "[entrypoint-v9] WARNING: /data not mounted, using /home/node/.openclaw\n"
  mkdir -p /home/node/.openclaw 2>&1 || true
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
find "$STATE_DIR" -name "*.lock" -delete 2>/dev/null || true

# ── Disk cleanup ────────────────────────────────────────────────
find "$STATE_DIR" -name "openclaw.json.backup*" -delete 2>/dev/null || true
find "$STATE_DIR" -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +1 -delete 2>/dev/null || true
find "$STATE_DIR" -type f -path "*/transcripts/*" -mtime +3 -delete 2>/dev/null || true
rm -rf "$STATE_DIR/completions" 2>/dev/null || true

printf "[entrypoint-v9] Disk cleanup done\n"

# ── ALWAYS regenerate seed config ───────────────────────────────
CONFIG_FILE="${STATE_DIR}/openclaw.json"
printf "[entrypoint-v9] Removing old config: %s\n" "$CONFIG_FILE"
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

printf "[entrypoint-v9] Config written to %s\n" "$CONFIG_FILE"

# Inject gateway token
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
if [ -n "$GATEWAY_TOKEN" ]; then
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const t = process.env.OPENCLAW_GATEWAY_TOKEN;
    try {
      const d = JSON.parse(fs.readFileSync(p, 'utf8'));
      d.gateway.auth = { token: t, mode: 'token' };
      fs.writeFileSync(p, JSON.stringify(d, null, 2));
      console.log('[entrypoint-v9] Gateway token set');
    } catch(e) {
      console.error('[entrypoint-v9] Token inject error: ' + e.message);
    }
  " "$CONFIG_FILE" 2>&1
fi

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
    console.log('[entrypoint-v9] Claude token written to ' + authPath);
  " "$AUTH_FILE" 2>&1 || printf "[entrypoint-v9] WARN: Claude token write failed\n"
fi

# ── Xvfb ────────────────────────────────────────────────────────
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
fi

# ── Start OpenClaw ──────────────────────────────────────────────
printf "[entrypoint-v9] ========================================\n"
printf "[entrypoint-v9] Starting: %s\n" "$*"
printf "[entrypoint-v9] ========================================\n"
exec "$@"
