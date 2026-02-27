FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      # Create symlink so OpenClaw's browser detection finds Chromium at /usr/bin/chromium
      CHROME_BIN=$(find /home/node/.cache/ms-playwright -type f -name 'chrome' \( -path '*/chrome-linux/*' -o -path '*/chrome-linux64/*' \) 2>/dev/null | head -1) && \
      if [ -n "$CHROME_BIN" ]; then \
        ln -sf "$CHROME_BIN" /usr/bin/chromium && \
        echo "Symlinked $CHROME_BIN -> /usr/bin/chromium"; \
      else \
        CHROME_BIN=$(find /home/node/.cache/ms-playwright -type f -name 'headless_shell' 2>/dev/null | head -1) && \
        if [ -n "$CHROME_BIN" ]; then \
          ln -sf "$CHROME_BIN" /usr/bin/chromium && \
          echo "Symlinked $CHROME_BIN -> /usr/bin/chromium"; \
        else \
          echo "WARNING: Playwright Chromium executable not found for symlink"; \
        fi; \
      fi && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

USER node
COPY --chown=node:node . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Switch to root for entrypoint installation
USER root

# Copy custom entrypoint script for persistent storage and config migration
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
USER node

# Use custom entrypoint for persistent storage setup and config migration
ENTRYPOINT ["docker-entrypoint.sh"]

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]
