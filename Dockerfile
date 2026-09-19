# syntax=docker/dockerfile:1
# DeepSeek Harness (`dsh`) container image.
#
# Two runtime variants share one builder:
#   min  — web profile only. Drops tree/website/snapshot fixtures and dependency
#          trees that are dev/test-only tooling or providers the `web`
#          composition does not mount (codex and Claude Code subagents, the
#          experimental CUA driver). Smallest deployable image.
#   full — every shipped profile and provider; only the VCS history is dropped.
#
# Multi-stage build from the local checkout:
#   1. builder — installs dependencies with pnpm and runs `pnpm run build`
#              (host native addon, tsc/tsdown lib output, web frontend).
#              Needs git: scripts/client-build-environment.ts stamps the build
#              from `git rev-parse HEAD`, so .git must stay in the context.
#   2. runtime — slim Node image with the built tree, launched through the
#              same source entrypoint the repo uses (`pnpm dsh ...`).
#              Full node_modules are kept because the launcher runs through
#              tsx (a devDependency).
#
# The web profile serves on port 3080. DSH_HOME (sessions, profiles,
# credentials) lives in /data — mount a volume there to persist it.
# The model needs a provider key: pass -e DEEPSEEK_API_KEY=... at run time.
#
# The dai branch's client/connection links bigtangle-ts from the sibling wallet
# checkout (`link:../../../../wallet/packages/bigtangle-ts`), which is outside
# this build context. `./deploy.sh` stages that package (the dir is gitignored;
# its own deps are installed in-image) and runs the build:
#   ./deploy.sh [image-tag] [min|full|both]
#   defaults: ghcr.io/bigt-ai-platform/deepseek-harness:latest, both

ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-bookworm AS builder

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare pnpm@11.28.5 --activate

# Toolchain for the host native addon and node-gyp fallbacks, plus git for
# build version stamping (see header).
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential python3 git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
# The dai branch links bigtangle-ts from the sibling wallet checkout, which is
# outside this build context. The staged copy lands at /app/bigtangle-ts; the
# link resolves to the absolute path below, so satisfy it before install, and
# give the package its own deps (the wallet monorepo hoists them at its root,
# so the staged copy is not self-contained).
RUN mkdir -p /wallet/packages \
  && ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts \
  && cd /app/bigtangle-ts \
  && npm install --omit=dev --ignore-scripts --no-audit --no-fund
RUN pnpm install --frozen-lockfile && pnpm run build

# `full`: the only tree a running profile never reads is the VCS history, which
# existed solely for the build stamp above.
FROM builder AS builder-full
RUN rm -rf /app/.git

# `min`: additionally drop source/test fixtures a running `web` profile never
# reads, and dependency trees that are dev/test-only tooling or providers the
# `web` composition does not mount. esbuild and typescript stay: `tsx` and the
# type tooling resolve them at runtime.
FROM builder AS builder-min
RUN set -eux; \
  rm -rf /app/.git /app/snapshots /app/website /app/benchmarks /app/python; \
  for p in lefthook playwright @playwright happy-dom vitest @vitest @testing-library \
           electron-winstaller jscpd publint @oxlint oxlint typescript-language-server \
           @stylistic @types pnpm tsdown rolldown @rolldown \
           @openai+codex @anthropic-ai+claude-agent-sdk @trycua+cua-driver; do \
    rm -rf "/app/node_modules/.pnpm/${p}"* "/app/node_modules/${p}" 2>/dev/null || true; \
  done

FROM node:${NODE_VERSION}-bookworm-slim AS runtime-base

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  NODE_ENV=production \
  DSH_HOME=/data

# pnpm for `dsh plugin ...` profile transactions; git for git-based plugins.
# /wallet/packages holds the out-of-context bigtangle-ts link; create it here
# (as root) and hand it to `node` so the targets can link without root.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable && corepack prepare pnpm@11.28.5 --activate \
  && mkdir -p /data /wallet/packages && chown node:node /data /wallet/packages

WORKDIR /app
USER node
VOLUME /data
EXPOSE 3080

ENTRYPOINT ["node", "--import", "tsx/esm", "apps/cli/src/bin.ts"]
CMD ["web", "--host", "0.0.0.0", "--port", "3080", "--no-open"]

# ── full: every shipped profile and provider ────────────────────────────────
FROM runtime-base AS full
COPY --from=builder-full --chown=node:node /app /app
# same out-of-context link as the builder stage
RUN ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts

# ── min: web profile only, pruned ───────────────────────────────────────────
FROM runtime-base AS min
COPY --from=builder-min --chown=node:node /app /app
RUN ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts
