# ── Stage 1: Builder ─────────────────────────────────────────────
FROM node:22-bookworm AS builder

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Strip devDependencies from node_modules
RUN pnpm prune --prod

# ── Stage 1b: Binary builder (optional, use --target binary-runtime) ──
FROM builder AS binary-builder
RUN bun build ./src/entry.ts --compile --minify --outfile /app/dist/openclaw

# ── Stage 2: Runtime ─────────────────────────────────────────────
FROM node:22-bookworm-slim

# bookworm-slim (not distroless) because the main app needs shell
# for sandbox features and optional apt packages.

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

WORKDIR /app

# Copy only production artifacts from builder
COPY --from=builder /app/dist/ ./dist/
COPY --from=builder /app/node_modules/ ./node_modules/
COPY --from=builder /app/openclaw.mjs ./openclaw.mjs
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/ui/dist/ ./ui/dist/
COPY --from=builder /app/assets/ ./assets/
COPY --from=builder /app/extensions/ ./extensions/
COPY --from=builder /app/skills/ ./skills/
COPY --from=builder /app/docs/ ./docs/

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
# The node:22-bookworm-slim image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
