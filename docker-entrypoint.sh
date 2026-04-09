#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup, config initialization, and migration
# v2 - simplified: no proxy bridge, gateway runs directly on 18789

set -e

# ── Persistent storage setup ────────────────────────────────────
# Ensure ~/.openclaw is always on the persistent disk at /data/.openclaw
if [ -d /data ]; then
  if [ ! -d /data/.openclaw ]; then
    echo "[entrypoint] Creating /data/.openclaw for persistent storage..."
    # If there's existing data in ~/.openclaw (from container image), migrate it
    if [ -d /home/node/.openclaw ] && [ ! -L /home/node/.openclaw ]; then
      echo "[entrypoint] Migrating existing ~/.openclaw data to /data/.openclaw..."
      cp -a /home/node/.openclaw /data/.openclaw
      echo "[entrypoint] Migration complete"
    else
      mkdir -p /data/.openclaw
    fi
    chown -R node:node /data/.openclaw 2>/dev/null || true
  fi

  # Create symlink: ~/.openclaw -> /data/.openclaw
  if [ -L /home/node/.openclaw ]; then
    echo "[entrypoint] Symlink already exists"
  else
    rm -rf /home/node/.openclaw
    ln -s /data/.openclaw /home/node/.openclaw
    echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"
  fi
  echo "[entrypoint] Disk usage:" && (df -h /data || true)
else
  echo "[entrypoint] WARNING: /data not mounted, data will NOT persist across deploys!"
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
  echo "[entrypoint] Playwright browsers found at: $PLAYWRIGHT_BROWSERS_PATH"
fi

# ── Config initialization ─────────────────────────────────────────
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
CONFIG_FILE="${STATE_DIR}/openclaw.json"
echo "[entrypoint] Config path: $CONFIG_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[entrypoint] Creating seed config for Render environment..."
  mkdir -p "$STATE_DIR"

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
            primary: 'openai-codex/gpt-5.4'
          },
          sandbox: {
            mode: 'off',
            browser: { allowHostControl: true }
          }
        }
      }
    };

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
      if (d.agents.defaults.model.primary !== 'openai-codex/gpt-5.4') {
        d.agents.defaults.model.primary = 'openai-codex/gpt-5.4';
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

# ── Telegram Bot Token injection ──────────────────────────────────
TELEGRAM_BOT_TOKEN_ENV="${TELEGRAM_BOT_TOKEN:-}"
if [ -n "$TELEGRAM_BOT_TOKEN_ENV" ]; then
  echo "[entrypoint] Configuring Telegram bot..."
  node -e "
    const fs = require('fs');
    const configPath = process.argv[1];
    const botToken = process.env.TELEGRAM_BOT_TOKEN || '';

    try {
      let config = {};
      if (fs.existsSync(configPath)) {
        config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      }
      let changed = false;

      if (!config.channels) config.channels = {};
      if (!config.channels.telegram) config.channels.telegram = {};
      if (config.channels.telegram.botToken !== botToken) {
        config.channels.telegram.botToken = botToken;
        changed = true;
      }
      if (!config.channels.telegram.enabled) {
        config.channels.telegram.enabled = true;
        changed = true;
      }
      if (!config.channels.telegram.dmPolicy) {
        config.channels.telegram.dmPolicy = 'pairing';
        changed = true;
      }
      if (!config.channels.telegram.groups) {
        config.channels.telegram.groups = { '*': { requireMention: true } };
        changed = true;
      }

      if (changed) {
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        console.log('[entrypoint] Telegram bot configured: token=' + botToken.substring(0, 12) + '...');
      } else {
        console.log('[entrypoint] Telegram config OK: no changes needed');
      }
    } catch(e) {
      console.error('[entrypoint] Telegram config error:', e.message);
    }
  " "$CONFIG_FILE"
else
  echo "[entrypoint] No TELEGRAM_BOT_TOKEN env var set, skipping Telegram config"
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

# ── Start gateway directly ────────────────────────────────────────
# v2: No proxy bridge. Gateway runs directly on port 18789.
# The upstream v2026.3.29 fixes the Telegram plugin recursive import
# that previously caused "Maximum call stack size exceeded" crashes.
echo "[entrypoint] Starting OpenClaw gateway directly on port 18789..."
exec "$@"
