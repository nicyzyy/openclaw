#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup, config initialization, and migration

# Setup symlink for persistent storage
if [ -d /data/.openclaw ]; then
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"
  echo "[entrypoint] Disk usage before cleanup:" && (df -h /data || true)
  # ENOSPC mitigation: prune stale logs/transcripts on persistent volume
  find /data/.openclaw -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +2 -print -delete 2>/dev/null || true
  find /tmp/openclaw -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +1 -print -delete 2>/dev/null || true
  find /data/.openclaw -type f -path "*/transcripts/*" -mtime +14 -print -delete 2>/dev/null || true
  echo "[entrypoint] Disk usage after cleanup:" && (df -h /data || true)
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
RESET_MARKER="${STATE_DIR}/.config-reset-v2"
echo "[entrypoint] Config path: $CONFIG_FILE"

# One-time config reset: backup old config and let OpenClaw generate fresh defaults
# The marker file ensures this only runs once per persistent volume
if [ -f "$CONFIG_FILE" ] && [ ! -f "$RESET_MARKER" ]; then
  BACKUP_NAME="openclaw.json.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_FILE" "${STATE_DIR}/${BACKUP_NAME}"
  echo "[entrypoint] Backed up old config to ${BACKUP_NAME}"
  rm -f "$CONFIG_FILE"
  echo "[entrypoint] Removed old config — OpenClaw will generate fresh defaults on startup"
  touch "$RESET_MARKER"
  echo "[entrypoint] Config reset complete (marker: .config-reset-v2)"
fi

# If config file exists (either pre-existing or will be created by OpenClaw),
# apply Render-specific settings after OpenClaw creates it.
# We use a post-start config patch approach: write a minimal seed config
# that OpenClaw will merge with its defaults on first start.
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
      console.log('[entrypoint] No OPENCLAW_GATEWAY_TOKEN env var set — gateway will start without token auth');
    }

    fs.writeFileSync(process.argv[1], JSON.stringify(config, null, 2));
    console.log('[entrypoint] Seed config written successfully');
  " "$CONFIG_FILE"
else
  # Config file exists — apply incremental patches
  echo "[entrypoint] Patching existing config..."
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const envToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
    try {
      const d = JSON.parse(fs.readFileSync(p, 'utf8'));
      let changed = false;

      // Ensure Render-required gateway settings
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

      // Configure trustedProxies for Render's reverse proxy
      const renderProxyCIDRs = ['10.0.0.0/8', '172.16.0.0/12'];
      if (!d.gateway.trustedProxies || JSON.stringify(d.gateway.trustedProxies) !== JSON.stringify(renderProxyCIDRs)) {
        d.gateway.trustedProxies = renderProxyCIDRs;
        changed = true;
      }

      // Sync gateway token from environment variable
      if (envToken) {
        if (!d.gateway.auth) d.gateway.auth = {};
        if (d.gateway.auth.token !== envToken) {
          d.gateway.auth.token = envToken;
          d.gateway.auth.mode = 'token';
          changed = true;
          console.log('[entrypoint] Gateway token synced from env var');
        }
      } else {
        if (d.gateway && d.gateway.auth && d.gateway.auth.token) {
          delete d.gateway.auth.token;
          delete d.gateway.auth.mode;
          if (Object.keys(d.gateway.auth).length === 0) delete d.gateway.auth;
          changed = true;
          console.log('[entrypoint] Cleared residual gateway token');
        }
      }

      // Set default model to Claude Opus 4.6
      if (!d.agents) d.agents = {};
      if (!d.agents.defaults) d.agents.defaults = {};
      if (!d.agents.defaults.model) d.agents.defaults.model = {};
      if (d.agents.defaults.model.primary !== 'anthropic/claude-opus-4-6') {
        d.agents.defaults.model.primary = 'anthropic/claude-opus-4-6';
        changed = true;
        console.log('[entrypoint] Default model set to anthropic/claude-opus-4-6');
      }

      // Ensure sandbox mode off
      if (!d.agents) d.agents = {};
      if (!d.agents.defaults) d.agents.defaults = {};
      if (!d.agents.defaults.sandbox) d.agents.defaults.sandbox = {};
      if (d.agents.defaults.sandbox.mode !== 'off') {
        d.agents.defaults.sandbox.mode = 'off';
        changed = true;
      }
      if (!d.agents.defaults.sandbox.browser) d.agents.defaults.sandbox.browser = {};
      if (!d.agents.defaults.sandbox.browser.allowHostControl) {
        d.agents.defaults.sandbox.browser.allowHostControl = true;
        changed = true;
      }

      if (changed) {
        fs.writeFileSync(p, JSON.stringify(d, null, 2));
        console.log('[entrypoint] Config patched successfully');
      } else {
        console.log('[entrypoint] Config OK: no changes needed');
      }
    } catch(e) {
      console.error('[entrypoint] Config patch error:', e.message);
    }
  " "$CONFIG_FILE"
fi

# ── Claude setup-token injection ─────────────────────────────────
# Write Claude setup-token to auth-profiles.json and update openclaw.json
CLAUDE_SETUP_TOKEN="${CLAUDE_SETUP_TOKEN:-}"
ANTHROPIC_API_KEY_ENV="${ANTHROPIC_API_KEY:-}"
if [ -n "$CLAUDE_SETUP_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY_ENV" ]; then
  echo "[entrypoint] Configuring Anthropic auth profiles..."
  AGENT_DIR="${STATE_DIR}/agents/main/agent"
  AUTH_PROFILES_FILE="${AGENT_DIR}/auth-profiles.json"
  mkdir -p "$AGENT_DIR"

  node -e "
    const fs = require('fs');
    const path = require('path');
    const authPath = process.argv[1];
    const configPath = process.argv[2];
    const setupToken = process.env.CLAUDE_SETUP_TOKEN || '';
    const apiKey = process.env.ANTHROPIC_API_KEY || '';

    // Load or create auth-profiles.json
    let store = { version: 2, profiles: {} };
    try {
      if (fs.existsSync(authPath)) {
        store = JSON.parse(fs.readFileSync(authPath, 'utf8'));
      }
    } catch(e) {
      console.log('[entrypoint] Could not read existing auth-profiles.json, creating new');
    }

    let authChanged = false;

    // Add Claude setup-token as token profile
    if (setupToken) {
      const profileId = 'anthropic:setup-token';
      if (!store.profiles[profileId] || store.profiles[profileId].token !== setupToken) {
        store.profiles[profileId] = {
          type: 'token',
          provider: 'anthropic',
          token: setupToken
        };
        authChanged = true;
        console.log('[entrypoint] Claude setup-token profile written: ' + setupToken.substring(0, 20) + '...');
      }
    }

    // Add Anthropic API key as fallback profile
    if (apiKey) {
      const profileId = 'anthropic:api-key';
      if (!store.profiles[profileId] || store.profiles[profileId].key !== apiKey) {
        store.profiles[profileId] = {
          type: 'api_key',
          provider: 'anthropic',
          key: apiKey
        };
        authChanged = true;
        console.log('[entrypoint] Anthropic API key profile written');
      }
    }

    if (authChanged) {
      fs.writeFileSync(authPath, JSON.stringify(store, null, 2));
      console.log('[entrypoint] auth-profiles.json updated');
    }

    // Update openclaw.json to reference the auth profiles
    try {
      let config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      let configChanged = false;

      if (!config.auth) config.auth = {};
      if (!config.auth.profiles) config.auth.profiles = {};

      if (setupToken) {
        const pid = 'anthropic:setup-token';
        if (!config.auth.profiles[pid]) {
          config.auth.profiles[pid] = { provider: 'anthropic', mode: 'token' };
          configChanged = true;
        }
      }
      if (apiKey) {
        const pid = 'anthropic:api-key';
        if (!config.auth.profiles[pid]) {
          config.auth.profiles[pid] = { provider: 'anthropic', mode: 'api_key' };
          configChanged = true;
        }
      }

      // Set auth order: prefer setup-token, fallback to api-key
      const order = [];
      if (setupToken) order.push('anthropic:setup-token');
      if (apiKey) order.push('anthropic:api-key');
      if (order.length > 0) {
        if (!config.auth.order) config.auth.order = {};
        if (JSON.stringify(config.auth.order.anthropic) !== JSON.stringify(order)) {
          config.auth.order.anthropic = order;
          configChanged = true;
        }
      }

      if (configChanged) {
        fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        console.log('[entrypoint] openclaw.json auth config updated');
      }
    } catch(e) {
      console.error('[entrypoint] Config auth update error:', e.message);
    }
  " "$AUTH_PROFILES_FILE" "$CONFIG_FILE"
fi

# Start Xvfb virtual display if available
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
  echo "[entrypoint] Xvfb virtual display started on :99"
fi

# Execute the main command
echo "[entrypoint] Starting OpenClaw gateway..."
exec "$@"
