# syntax=docker/dockerfile:1
# DeepSeek Harness (`dsh`) container image.
#
# Two runtime variants:
#   min  — the packaged Linux application, stripped to its headless runtime: the
#          release closure (lib output only, no sources, no dev tooling, no tsx),
#          the bundled Python interpreter, and the Office WASM engine. Built from
#          the AppImage the Desktop packaging pipeline produces, so the container
#          ships exactly the payload the Desktop smoke check verified.
#   full — every shipped profile and provider, built from this checkout; only the
#          VCS history is dropped.
#
# Multi-stage build:
#   1. builder — installs dependencies with pnpm and runs `pnpm run build`
#              (host native addon, tsc/tsdown lib output, web frontend).
#              Needs git: scripts/client-build-environment.ts stamps the build
#              from `git rev-parse HEAD`, so .git must stay in the context.
#              Only `full` consumes this stage.
#   2. unpack  — extracts the AppImage and keeps the closure, dropping the
#              Electron shell (the GUI binary, Chromium resources and locales)
#              and the runtime's pnpm (the image provides it through corepack).
#   3. runtime — slim Node image; `full` copies the built checkout, `min` copies
#              the unpacked closure and Python.
#
# Both images serve the web profile on port 3080. The profile refuses wildcard
# hosts, so the entrypoint binds this container's own address, the interface a
# published port forwards to; pass a whole command to bind something else.
# DSH_HOME (sessions, profiles, credentials) lives in /data — mount a volume
# there to persist it. The model needs a provider key: pass
# -e DEEPSEEK_API_KEY=... at run time.
#
# `./deploy.sh` stages the dai branch's out-of-context bigtangle-ts link, builds
# the AppImage when it is absent, and runs the build:
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

# `min`: the packaged Linux application, reduced to the closure the `web` profile
# reads. The Desktop packaging pipeline (see deploy.sh) already packed, pruned
# and smoke-checked this payload, including the linked bigtangle-ts package.
FROM node:${NODE_VERSION}-bookworm-slim AS unpack
ARG APPIMAGE
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY ${APPIMAGE} /tmp/app.AppImage
RUN set -eux; \
  chmod +x /tmp/app.AppImage; \
  cd /tmp; \
  /tmp/app.AppImage --appimage-extract >/dev/null; \
  mv /tmp/squashfs-root /opt/app; \
  rm -f /tmp/app.AppImage; \
  cd /opt/app; \
  npx --yes @electron/asar extract resources/app.asar resources/app; \
  cp -r resources/app.asar.unpacked/dsh/. resources/app/dsh/; \
  rm -rf resources/app.asar resources/app.asar.unpacked resources/default_app.asar \
         resources/icon.png resources/apparmor-profile locales \
         resources/runtime/primary-runtime/dependencies/pnpm; \
  rm -f deepseek-harness chrome-sandbox chrome_crashpad_handler icudtl.dat \
        LICENSES.chromium.html LICENSE.electron.txt resources.pak \
        chrome_100_percent.pak chrome_200_percent.pak v8_context_snapshot.bin \
        snapshot_blob.bin vk_swiftshader_icd.json libvk_swiftshader.so \
        libffmpeg.so libvulkan.so.1 libEGL.so libGLESv2.so version

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

# The web profile rejects wildcard hosts, so the entrypoint binds this
# container's own address (see dsh-entrypoint.sh).
COPY --chown=root:root dsh-entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod 0755 /usr/local/bin/dsh-entrypoint

WORKDIR /app
USER node
VOLUME /data
EXPOSE 3080

ENV DSH_ENTRY=/app/apps/cli/src/bin.ts \
  NODE_OPTIONS=--import\ tsx/esm
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]

# ── full: every shipped profile and provider ────────────────────────────────
FROM runtime-base AS full
COPY --from=builder-full --chown=node:node /app /app
# same out-of-context link as the builder stage
RUN ln -s /app/bigtangle-ts /wallet/packages/bigtangle-ts

# ── min: the packaged Linux application, headless ───────────────────────────
FROM runtime-base AS min
COPY --from=unpack --chown=node:node /opt/app/resources/app/dsh /app/dsh
COPY --from=unpack --chown=node:node /opt/app/resources/runtime/primary-runtime/dependencies/python /app/runtime/python
# The closure is a complete production dependency tree, so the entrypoint is the
# packed CLI itself rather than the checkout's TypeScript source entrypoint.
ENV PATH=/app/runtime/python/bin:${PATH} \
  DSH_ENTRY=/app/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \
  NODE_OPTIONS=
