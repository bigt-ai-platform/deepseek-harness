#!/usr/bin/env bash
#
# Build the dsh container images from this checkout.
#
# The dai branch's client/connection package links bigtangle-ts from the sibling
# wallet checkout (`link:../../../../wallet/packages/bigtangle-ts`), a path
# outside this build context. Stage that package before building: the Dockerfile
# resolves the link through /wallet/packages/bigtangle-ts, which it points at
# /app/bigtangle-ts. The staged directory is gitignored.
#
# The `min` image is the packaged Linux application, so this script builds the
# AppImage first (the Desktop packaging pipeline packs, prunes and smoke-checks
# that payload) and hands it to the image build. Reuse an existing artifact with
# DSH_SKIP_PACKAGE=1, or point at one with DSH_APPIMAGE=<path>.
#
#   ./deploy.sh [image-tag] [min|full|both]
#     min   the packaged application, headless (default tag)
#     full  every shipped profile and provider, built from this checkout
#     both  build min under <image-tag> and full under <image-tag>-full
#
# defaults: image-tag ghcr.io/bigt-ai-platform/deepseek-harness:latest, variant both
set -euo pipefail

cd "$(dirname "$0")"

IMAGE_TAG="${1:-ghcr.io/bigt-ai-platform/deepseek-harness:latest}"
VARIANT="${2:-both}"
WALLET_PACKAGE="../wallet/packages/bigtangle-ts"
APPIMAGE_DIR="apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts"

case "$VARIANT" in
  min | full | both) ;;
  *) echo "error: variant must be min, full, or both (got '$VARIANT')" >&2; exit 1 ;;
esac
if [ ! -d "$WALLET_PACKAGE" ]; then
  echo "error: $WALLET_PACKAGE not found; clone the wallet checkout beside this repo" >&2
  exit 1
fi

# Print the AppImage the `min` image unpacks, building it when absent.
appimage() {
  if [ -n "${DSH_APPIMAGE:-}" ]; then
    if [ ! -f "$DSH_APPIMAGE" ]; then
      echo "error: DSH_APPIMAGE=$DSH_APPIMAGE is not a file" >&2
      exit 1
    fi
    printf '%s' "$DSH_APPIMAGE"
    return
  fi
  if [ "${DSH_SKIP_PACKAGE:-0}" != "1" ]; then
    echo "==> building the Linux AppImage (Desktop packaging pipeline)" >&2
    pnpm --dir apps/desktop run package:linux:x64:unsigned >&2
  fi
  local artifact
  artifact=$(ls -1t "$APPIMAGE_DIR"/*.AppImage 2>/dev/null | head -1 || true)
  if [ -z "$artifact" ]; then
    echo "error: no AppImage in $APPIMAGE_DIR; run 'pnpm --dir apps/desktop run package:linux:x64:unsigned' first" >&2
    exit 1
  fi
  printf '%s' "$artifact"
}

rm -rf bigtangle-ts
cp -a "$WALLET_PACKAGE" bigtangle-ts

build() { # target tag
  echo "==> building $2 (target $1)"
  if [ "$1" = "min" ]; then
    docker build --target min --build-arg "APPIMAGE=$(appimage)" -t "$2" .
  else
    docker build --target full -t "$2" .
  fi
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
