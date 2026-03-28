#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup, config initialization, and migration

# ── NUCLEAR OPTION: Full persistent storage reset ─────────────────
# The gateway has been failing to bind to port for 12+ deploys.
# Root cause: corrupted state in /data/.openclaw prevents gateway startup.
# Solution: move old data aside and start completely fresh.
NUKE_MARKER="/data/.nuke-reset-v1-done"
if [ -d /data/.openclaw ] && [ ! -f "$NUKE_MARKER" ]; then
  echo "[entrypoint] NUCLEAR RESET: Moving old .openclaw data aside..."
  mv /data/.openclaw /data/.openclaw-backup-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
  mkdir -p /data/.openclaw
  chown node:node /data/.openclaw 2>/dev/null || true
  touch "$NUKE_MARKER"
  echo "[entrypoint] NUCLEAR RESET: Fresh .openclaw directory created"
fi

# Setup symlink for persistent storage
if [ -d /data/.openclaw ]; then
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"
  echo "[entrypoint] Disk usage:" && (df -h /data || true)
fi

# Setup PATH for skills
if [ -d /data/npm-global/bin ]; then
  export PATH="/data/npm-global/bin:$PATH"
  export NPM_CONFIG_PREFIX=/data/npm-global
  echo "[entrypoint] Added skills to PATH: /data/npm-global/bin"
fi

# Setup Playwright browsers path (if Chromium was baked into the image)
if [ -d /home/node/.cache/ms-playwright ]; then
  export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
  echo "[entrypoint] Playwright browsers found at: $PLAYWRIGHT_BROWSERS_PATH"
fi

# ── Config initialization ─────────────────────────────────────────
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
CONFIG_FILE="${STATE_DIR}/openclaw.json"
echo "[entrypoint] Config path: $CONFIG_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[entrypoint] Creating seed config for Render environment..."
  mkdir -p "$STATE_DIR"

  # Build seed config with Render-specific settings
  node -e "
    const fs = require('fs');
    const envToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
    const config = {
      gateway: {
        controlUi: {
          dangerouslyAllowHostHeaderOriginFallback: true,
          dangerouslyDisableDeviceAuth: true
        },
        trustedProxies: ['10.0.0.0/8', '172.16.0.0/12']
      },
      agents: {
        defaults: {
          model: {
            primary: 'anthropic/claude-opus-4-6'
          },
          sandbox: {
            mode: 'off',
            browser: { allowHostControl: true }
          }
        }
      }
    };

    // Set gateway token if env var is provided
    if (envToken) {
      config.gateway.auth = {
        token: envToken,
        mode: 'token'
      };
      console.log('[entrypoint] Gateway token configured from env var: ' + envToken.substring(0, 12) + '...');
    } else {
      console.log('[entrypoint] No OPENCLAW_GATEWAY_TOKEN env var set');
    }

    fs.writeFileSync(process.argv[1], JSON.stringify(config, null, 2));
    console.log('[entrypoint] Seed config written successfully');
  " "$CONFIG_FILE"
else
  echo "[entrypoint] Config file exists, patching..."
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const envToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
    try {
      const d = JSON.parse(fs.readFileSync(p, 'utf8'));
      let changed = false;
      if (!d.gateway) d.gateway = {};
      if (!d.gateway.controlUi) d.gateway.controlUi = {};
      if (!d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback) {
        d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
        changed = true;
      }
      if (!d.gateway.controlUi.dangerouslyDisableDeviceAuth) {
        d.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
        changed = true;
      }
      const renderProxyCIDRs = ['10.0.0.0/8', '172.16.0.0/12'];
      if (JSON.stringify(d.gateway.trustedProxies) !== JSON.stringify(renderProxyCIDRs)) {
        d.gateway.trustedProxies = renderProxyCIDRs;
        changed = true;
      }
      if (envToken) {
        if (!d.gateway.auth) d.gateway.auth = {};
        if (d.gateway.auth.token !== envToken) {
          d.gateway.auth.token = envToken;
          d.gateway.auth.mode = 'token';
          changed = true;
        }
      }
      if (!d.agents) d.agents = {};
      if (!d.agents.defaults) d.agents.defaults = {};
      if (!d.agents.defaults.model) d.agents.defaults.model = {};
      if (d.agents.defaults.model.primary !== 'anthropic/claude-opus-4-6') {
        d.agents.defaults.model.primary = 'anthropic/claude-opus-4-6';
        changed = true;
      }
      if (changed) {
        fs.writeFileSync(p, JSON.stringify(d, null, 2));
        console.log('[entrypoint] Config patched');
      } else {
        console.log('[entrypoint] Config OK');
      }
    } catch(e) {
      console.error('[entrypoint] Config error:', e.message);
      try { fs.unlinkSync(p); } catch(e2) {}
    }
  " "$CONFIG_FILE"
fi

# ── Claude setup-token injection ─────────────────────────────────
CLAUDE_SETUP_TOKEN="${CLAUDE_SETUP_TOKEN:-}"
ANTHROPIC_API_KEY_ENV="${ANTHROPIC_API_KEY:-}"
if [ -n "$CLAUDE_SETUP_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY_ENV" ]; then
  echo "[entrypoint] Configuring Anthropic auth profiles..."
  AGENT_DIR="${STATE_DIR}/agents/main/agent"
  AUTH_PROFILES_FILE="${AGENT_DIR}/auth-profiles.json"
  mkdir -p "$AGENT_DIR"

  node -e "
    const fs = require('fs');
    const authPath = process.argv[1];
    const configPath = process.argv[2];
    const setupToken = process.env.CLAUDE_SETUP_TOKEN || '';
    const apiKey = process.env.ANTHROPIC_API_KEY || '';

    let store = { version: 2, profiles: {} };
    try {
      if (fs.existsSync(authPath)) {
        store = JSON.parse(fs.readFileSync(authPath, 'utf8'));
      }
    } catch(e) {}

    let authChanged = false;
    if (setupToken) {
      const pid = 'anthropic:setup-token';
      if (!store.profiles[pid] || store.profiles[pid].token !== setupToken) {
        store.profiles[pid] = { type: 'token', provider: 'anthropic', token: setupToken };
        authChanged = true;
        console.log('[entrypoint] Claude setup-token written');
      }
    }
    if (apiKey) {
      const pid = 'anthropic:api-key';
      if (!store.profiles[pid] || store.profiles[pid].key !== apiKey) {
        store.profiles[pid] = { type: 'api_key', provider: 'anthropic', key: apiKey };
        authChanged = true;
        console.log('[entrypoint] Anthropic API key written');
      }
    }
    if (authChanged) {
      fs.writeFileSync(authPath, JSON.stringify(store, null, 2));
    }

    // Update openclaw.json auth references
    try {
      let config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      let configChanged = false;
      if (!config.auth) config.auth = {};
      if (!config.auth.profiles) config.auth.profiles = {};
      if (setupToken && !config.auth.profiles['anthropic:setup-token']) {
        config.auth.profiles['anthropic:setup-token'] = { provider: 'anthropic', mode: 'token' };
        configChanged = true;
      }
      if (apiKey && !config.auth.profiles['anthropic:api-key']) {
        config.auth.profiles['anthropic:api-key'] = { provider: 'anthropic', mode: 'api_key' };
        configChanged = true;
      }
      const order = [];
      if (setupToken) order.push('anthropic:setup-token');
      if (apiKey) order.push('anthropic:api-key');
      if (order.length > 0) {
        if (!config.auth.order) config.auth.order = {};
        config.auth.order.anthropic = order;
        configChanged = true;
      }
      if (configChanged) {
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        console.log('[entrypoint] Auth config updated');
      }
    } catch(e) {
      console.error('[entrypoint] Auth config error:', e.message);
    }
  " "$AUTH_PROFILES_FILE" "$CONFIG_FILE"
fi

# Start Xvfb virtual display if available
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
  echo "[entrypoint] Xvfb started on :99"
fi

# ── Pre-flight diagnostics ────────────────────────────────────────
echo "[entrypoint] Pre-flight:"
echo "[entrypoint]   pwd=$(pwd) node=$(node --version)"
echo "[entrypoint]   PORT=${PORT:-not set}"
echo "[entrypoint]   config=$(test -f "$CONFIG_FILE" && echo "exists ($(wc -c < "$CONFIG_FILE")b)" || echo "missing")"
echo "[entrypoint]   cmd=$@"

# Execute the main command
echo "[entrypoint] Starting OpenClaw gateway..."
exec "$@" 2>&1
