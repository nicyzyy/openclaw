#!/bin/sh
# Custom entrypoint for OpenClaw on Render
# Handles persistent storage setup and config migration

# Setup symlink for persistent storage
if [ -d /data/.openclaw ]; then
  rm -rf /home/node/.openclaw
  ln -s /data/.openclaw /home/node/.openclaw
  echo "[entrypoint] Linked persistent storage: /data/.openclaw -> /home/node/.openclaw"
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

# Fix deprecated config keys (auto-migration)
# Use OPENCLAW_STATE_DIR if set, otherwise fall back to ~/.openclaw
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
CONFIG_FILE="${STATE_DIR}/openclaw.json"
echo "[entrypoint] Config path: $CONFIG_FILE"

if [ -f "$CONFIG_FILE" ]; then
  node -e "
    const fs = require('fs');
    const p = process.argv[1];
    const envToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
    const playwrightPath = process.env.PLAYWRIGHT_BROWSERS_PATH || '';
    try {
      const d = JSON.parse(fs.readFileSync(p, 'utf8'));
      let changed = false;

      // Remove deprecated keys that cause validation errors
      if (d.commands && d.commands.ownerDisplay !== undefined) {
        delete d.commands.ownerDisplay;
        changed = true;
      }
      if (d.channels && d.channels.telegram && d.channels.telegram.streaming !== undefined) {
        delete d.channels.telegram.streaming;
        changed = true;
      }

      // Ensure controlUi config for non-loopback binding (required since v2026.2.24)
      if (!d.gateway) d.gateway = {};
      if (!d.gateway.controlUi) d.gateway.controlUi = {};
      if (!d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback) {
        d.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
        changed = true;
      }

      // Disable device pairing requirement for Control UI
      // Required for remote (non-localhost) browser access via Render
      if (!d.gateway.controlUi.dangerouslyDisableDeviceAuth) {
        d.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
        changed = true;
        console.log('[entrypoint] Disabled Control UI device auth (pairing not required)');
      }

      // Configure trustedProxies for Render's reverse proxy
      // Render uses internal IPs (10.x.x.x) as proxy addresses
      // Without this, all WebSocket connections are rejected as 'untrusted proxy'
      const renderProxyCIDRs = ['10.0.0.0/8', '172.16.0.0/12'];
      if (!d.gateway.trustedProxies || JSON.stringify(d.gateway.trustedProxies) !== JSON.stringify(renderProxyCIDRs)) {
        d.gateway.trustedProxies = renderProxyCIDRs;
        changed = true;
        console.log('[entrypoint] Configured trustedProxies for Render: ' + renderProxyCIDRs.join(', '));
      }

      // Sync gateway token from environment variable to config file
      // This ensures the config file token matches the env var token
      if (envToken) {
        if (!d.gateway.auth) d.gateway.auth = {};
        if (d.gateway.auth.token !== envToken) {
          const oldToken = d.gateway.auth.token || '(not set)';
          d.gateway.auth.token = envToken;
          d.gateway.auth.mode = 'token';
          changed = true;
          console.log('[entrypoint] Gateway token synced from env var (old: ' + oldToken.substring(0,8) + '..., new: ' + envToken.substring(0,8) + '...)');
        } else {
          console.log('[entrypoint] Gateway token already matches env var');
        }
      }

      // Disable sandbox mode (no Docker-in-Docker on Render) and allow host browser control
      // This ensures the browser tool defaults to target="host" without requiring explicit parameter
      if (!d.agents) d.agents = {};
      if (!d.agents.defaults) d.agents.defaults = {};
      if (!d.agents.defaults.sandbox) d.agents.defaults.sandbox = {};
      if (d.agents.defaults.sandbox.mode !== 'off') {
        d.agents.defaults.sandbox.mode = 'off';
        changed = true;
        console.log('[entrypoint] Sandbox mode disabled (no Docker-in-Docker on Render)');
      }
      if (!d.agents.defaults.sandbox.browser) d.agents.defaults.sandbox.browser = {};
      if (!d.agents.defaults.sandbox.browser.allowHostControl) {
        d.agents.defaults.sandbox.browser.allowHostControl = true;
        changed = true;
        console.log('[entrypoint] Browser host control allowed for sandbox sessions');
      }

      // Enable browser automation if Playwright Chromium is installed
      // This allows the agent to browse the web, take screenshots, click, type, etc.
      if (playwrightPath) {
        if (!d.browser) d.browser = {};

        // Find the actual Playwright Chromium executable path
        // Playwright installs Chromium under ms-playwright/chromium-XXXX/chrome-linux64/chrome (or chrome-linux/chrome)
        const fs2 = require('fs');
        const path2 = require('path');
        let chromiumExe = '';
        try {
          const entries = fs2.readdirSync(playwrightPath);
          const chromiumDir = entries.find(e => e.startsWith('chromium-'));
          if (chromiumDir) {
            const candidatePaths = [
              path2.join(playwrightPath, chromiumDir, 'chrome-linux64', 'chrome'),
              path2.join(playwrightPath, chromiumDir, 'chrome-linux', 'chrome'),
              path2.join(playwrightPath, chromiumDir, 'chrome-linux64', 'headless_shell'),
              path2.join(playwrightPath, chromiumDir, 'chrome-linux', 'headless_shell'),
              path2.join(playwrightPath, chromiumDir, 'chrome'),
            ];
            for (const cp of candidatePaths) {
              if (fs2.existsSync(cp)) {
                chromiumExe = cp;
                break;
              }
            }
          }
        } catch(e2) {
          console.error('[entrypoint] Error finding Playwright Chromium:', e2.message);
        }

        const browserChanged =
          !d.browser.enabled ||
          !d.browser.headless ||
          !d.browser.noSandbox ||
          d.browser.defaultProfile !== 'openclaw' ||
          (chromiumExe && d.browser.executablePath !== chromiumExe);
        if (browserChanged) {
          d.browser.enabled = true;
          d.browser.headless = true;
          d.browser.noSandbox = true;
          d.browser.defaultProfile = 'openclaw';
          if (chromiumExe) {
            d.browser.executablePath = chromiumExe;
            console.log('[entrypoint] Browser automation enabled (Chromium at: ' + chromiumExe + ')');
          } else {
            console.log('[entrypoint] Browser automation enabled but Chromium executable not found in Playwright dir');
          }
          changed = true;
        } else {
          console.log('[entrypoint] Browser automation already configured');
        }
      }

      if (changed) {
        fs.writeFileSync(p, JSON.stringify(d, null, 2));
        console.log('[entrypoint] Config updated successfully');
      } else {
        console.log('[entrypoint] Config OK: no changes needed');
      }
    } catch(e) {
      console.error('[entrypoint] Config check error:', e.message);
    }
  " "$CONFIG_FILE"
else
  echo "[entrypoint] Config file not found at $CONFIG_FILE, skipping fix"
fi

# Start Xvfb virtual display if available (needed for non-headless browser or as fallback)
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
  echo "[entrypoint] Xvfb virtual display started on :99"
fi

# Pre-warm Chromium browser profile to avoid bootstrap delay during first browser tool call
# OpenClaw's Chrome launcher needs Local State and Default/Preferences files to exist.
# Without pre-warming, the first browser call triggers a bootstrap phase that can timeout.
BROWSER_USER_DATA="${STATE_DIR}/browser/openclaw/user-data"
CHROMIUM_EXE="/usr/bin/chromium"
if [ -x "$CHROMIUM_EXE" ] && [ ! -f "${BROWSER_USER_DATA}/Local State" ]; then
  echo "[entrypoint] Pre-warming Chromium profile (creating user-data dir)..."
  mkdir -p "$BROWSER_USER_DATA"
  # Launch Chromium briefly to generate profile files, then kill it
  $CHROMIUM_EXE --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port=18800 --user-data-dir="$BROWSER_USER_DATA" \
    --no-first-run --no-default-browser-check about:blank &
  CHROME_PID=$!
  # Wait up to 15 seconds for profile files to be created
  WARMUP_DEADLINE=15
  WARMUP_ELAPSED=0
  while [ $WARMUP_ELAPSED -lt $WARMUP_DEADLINE ]; do
    if [ -f "${BROWSER_USER_DATA}/Local State" ] && [ -d "${BROWSER_USER_DATA}/Default" ]; then
      echo "[entrypoint] Chromium profile created successfully"
      break
    fi
    sleep 1
    WARMUP_ELAPSED=$((WARMUP_ELAPSED + 1))
  done
  # Kill the warm-up Chrome process
  kill $CHROME_PID 2>/dev/null
  wait $CHROME_PID 2>/dev/null
  echo "[entrypoint] Chromium pre-warm complete (${WARMUP_ELAPSED}s)"
else
  if [ -x "$CHROMIUM_EXE" ]; then
    echo "[entrypoint] Chromium profile already exists, skipping pre-warm"
  fi
fi

# Execute the main command
echo "[entrypoint] Starting OpenClaw gateway..."
exec "$@"
