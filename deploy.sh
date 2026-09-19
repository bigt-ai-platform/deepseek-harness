#!/usr/bin/env bash
#
# Build the dsh container image from this checkout.
#
# The dai branch's client/connection package links bigtangle-ts from the sibling
# wallet checkout (`link:../../../../wallet/packages/bigtangle-ts`), a path
# outside this build context. Stage that package before building: the Dockerfile
# resolves the link through /wallet/packages/bigtangle-ts, which it points at
# /app/bigtangle-ts. The staged directory is gitignored.
#
#   ./deploy.sh [image-tag] [min|full|both]
#     min   web profile only, pruned (default tag)
#     full  every shipped profile and provider
#     both  build min under <image-tag> and full under <image-tag>-full
#
# defaults: image-tag ghcr.io/bigt-ai-platform/deepseek-harness:latest, variant both
set -euo pipefail

cd "$(dirname "$0")"

IMAGE_TAG="${1:-ghcr.io/bigt-ai-platform/deepseek-harness:latest}"
VARIANT="${2:-both}"
WALLET_PACKAGE="../wallet/packages/bigtangle-ts"

case "$VARIANT" in
  min | full | both) ;;
  *) echo "error: variant must be min, full, or both (got '$VARIANT')" >&2; exit 1 ;;
esac
if [ ! -d "$WALLET_PACKAGE" ]; then
  echo "error: $WALLET_PACKAGE not found; clone the wallet checkout beside this repo" >&2
  exit 1
fi

rm -rf bigtangle-ts
cp -a "$WALLET_PACKAGE" bigtangle-ts

build() { # target tag
  echo "==> building $2 (target $1)"
  docker build --target "$1" -t "$2" .
  docker image inspect "$2" --format '    {{.RepoTags}} {{.Size}} bytes'
}

case "$VARIANT" in
  min) build min "$IMAGE_TAG" ;;
  full) build full "$IMAGE_TAG" ;;
  both)
    build min "$IMAGE_TAG"
    build full "$IMAGE_TAG-full"
    ;;
esac
