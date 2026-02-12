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
RUN node scripts/generate-integrity.mjs
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Strip devDependencies from node_modules
RUN CI=true pnpm prune --prod

# ── Stage 1b: Binary builder ──
FROM builder AS binary-builder
RUN bun build ./src/entry.ts --compile --minify --outfile /app/openclaw \
    --external '@node-llama-cpp/*' \
    --external chromium-bidi \
    --external electron

# ── Stage 2: Runtime ─────────────────────────────────────────────
FROM debian:bookworm-slim

# bookworm-slim (not distroless) because the main app needs shell
# for sandbox features and optional apt packages.

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN --mount=type=tmpfs,target=/var/cache/apt/archives \
    if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      rm -rf /var/lib/apt/lists/* && \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user (no longer provided by node base image)
RUN groupadd --gid 1000 node && useradd --uid 1000 --gid node --create-home node

WORKDIR /app

# Copy compiled binary and runtime assets from binary-builder.
# Binary lives at /app/openclaw so extensions/, skills/, assets/, docs/
# are siblings — matching resolveBundledPluginsDir / resolveBundledSkillsDir
# (sibling-of-execPath lookup).
COPY --from=binary-builder /app/openclaw ./openclaw
COPY --from=binary-builder /app/dist/ ./dist/
COPY --from=binary-builder /app/package.json ./package.json
COPY --from=binary-builder /app/extensions/ ./extensions/
COPY --from=binary-builder /app/skills/ ./skills/
COPY --from=binary-builder /app/assets/ ./assets/
COPY --from=binary-builder /app/docs/ ./docs/
ENV NODE_ENV=production
# Bun binary does not support Node's --disable-warning flag; skip the respawn.
ENV OPENCLAW_NO_RESPAWN=1

# Allow non-root user to write temp files during runtime.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["./openclaw","gateway","--allow-unconfigured","--bind","lan"]
CMD ["./openclaw", "gateway", "--allow-unconfigured"]
