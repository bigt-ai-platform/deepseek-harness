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
# that payload) and stages it as app-image.AppImage for the image build. Reuse an
# existing artifact with DSH_SKIP_PACKAGE=1, or point at one with
# DSH_APPIMAGE=<path>.
#
# Version. Every run derives a released (stable) deploy version from the newest
# `v*` git tag (legacy `dsh-v*` tags are read too) and the workspace version,
# creates an annotated git tag `v<version>`, and tags the images with it
# alongside `latest`:
#   · a prerelease releases as its numbers — `0.2.1-alpha.3` -> `0.2.1`
#   · a stable version advances its patch — `0.2.1` -> `0.2.2`
# The tag is created only after the images build; it is not pushed unless
# DSH_PUSH_TAG=1. Override the version with DSH_VERSION=<x.y.z>, or skip the git
# tag entirely with DSH_NO_TAG=1.
#
#   ./deploy.sh [image-repo] [min|full|both]
#     image-repo  registry/namespace/repo without a tag; a trailing ":tag" is
#                 stripped, because the version above owns the tag
#     min         the packaged application, headless
#     full        every shipped profile and provider, built from this checkout
#     both        build min under <image-repo>:<version> and full under
#                 <image-repo>:<version>-full
#
# defaults: image-repo ghcr.io/bigt-ai-platform/deepseek-harness, variant both
set -euo pipefail

cd "$(dirname "$0")"

IMAGE_REPO="${1:-ghcr.io/bigt-ai-platform/deepseek-harness}"
VARIANT="${2:-both}"
WALLET_PACKAGE="../wallet/packages/bigtangle-ts"
APPIMAGE_DIR="apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts"

# The deploy version owns the tag: drop a trailing ":tag" from the repository
# argument, but leave a registry port (`host:5000/repo`) alone.
TAG_TAIL="${IMAGE_REPO##*:}"
if [ "$TAG_TAIL" != "$IMAGE_REPO" ] && [[ "$TAG_TAIL" != */* ]]; then
  IMAGE_REPO="${IMAGE_REPO%:*}"
fi

case "$VARIANT" in
  min | full | both) ;;
  *) echo "error: variant must be min, full, or both (got '$VARIANT')" >&2; exit 1 ;;
esac
if [ ! -d "$WALLET_PACKAGE" ]; then
  echo "error: $WALLET_PACKAGE not found; clone the wallet checkout beside this repo" >&2
  exit 1
fi

# The released deploy version (see the header). DSH_VERSION passes it through.
version() {
  if [ -n "${DSH_VERSION:-}" ]; then
    printf '%s' "$DSH_VERSION"
    return
  fi
  node --input-type=module <<'NODE'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const parse = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(v)
  return m === null ? null : { nums: [+m[1], +m[2], +m[3]], pre: m[4] }
}
const cmpPre = (a, b) => {
  if (a === undefined && b === undefined) return 0
  if (a === undefined) return 1
  if (b === undefined) return -1
  const A = a.split('.')
  const B = b.split('.')
  for (let i = 0; i < Math.max(A.length, B.length); i += 1) {
    const x = A[i]
    const y = B[i]
    if (x === undefined) return -1
    if (y === undefined) return 1
    if (x === y) continue
    const xn = /^\d+$/.test(x)
    const yn = /^\d+$/.test(y)
    if (xn && yn) return Number(x) - Number(y)
    if (xn !== yn) return xn ? -1 : 1
    return x < y ? -1 : 1
  }
  return 0
}
const cmp = (a, b) => {
  for (let i = 0; i < 3; i += 1) if (a.nums[i] !== b.nums[i]) return a.nums[i] - b.nums[i]
  return cmpPre(a.pre, b.pre)
}

const tags = execFileSync('git', ['tag', '--list', 'v*', 'dsh-v*'], { encoding: 'utf8' })
  .split('\n').filter((line) => line !== '')
  .map((tag) => {
    const m = /^(?:dsh-)?v(.+)$/.exec(tag)
    return m === null ? null : m[1]
  })
  .filter((version) => version !== null)
const manifest = JSON.parse(readFileSync('package.json', 'utf8')).version
const candidates = [...tags, manifest].map(parse).filter((v) => v !== null)
const max = candidates.reduce((a, b) => (cmp(b, a) > 0 ? b : a))
const existing = new Set(tags)
// Released version: drop a prerelease; a stable version advances its patch.
let nums = max.pre === undefined ? [max.nums[0], max.nums[1], max.nums[2] + 1] : [...max.nums]
while (existing.has(nums.join('.'))) nums = [nums[0], nums[1], nums[2] + 1]
process.stdout.write(nums.join('.'))
NODE
}

VERSION="$(version)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: not a semver deploy version: '$VERSION'" >&2
  exit 1
fi
GIT_TAG="v$VERSION"

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

# The image build context carries exactly one Desktop artifact; the packaging
# tree beside it stays out (see .dockerignore).
STAGED_APPIMAGE="app-image.AppImage"
cleanup() { rm -f "$STAGED_APPIMAGE"; }
trap cleanup EXIT

echo "==> deploy version $VERSION ($GIT_TAG)"

# Tag one variant: <repo>:<version><suffix> plus <repo>:latest<suffix>.
build() { # target suffix
  local target="$1" suffix="$2"
  local primary="$IMAGE_REPO:$VERSION$suffix"
  local latest="$IMAGE_REPO:latest$suffix"
  echo "==> building $primary (target $target)"
  if [ "$target" = "min" ]; then
    cp "$(appimage)" "$STAGED_APPIMAGE"
    docker build --target min -t "$primary" -t "$latest" .
  else
    docker build --target full -t "$primary" -t "$latest" .
  fi
  docker image inspect "$primary" --format '    {{.RepoTags}} {{.Size}} bytes'
}

case "$VARIANT" in
  min) build min "" ;;
  full) build full "-full" ;;
  both)
    build min ""
    build full "-full"
    ;;
esac

# Tag the source last, so a failed build never leaves a dangling deploy tag.
if [ "${DSH_NO_TAG:-0}" != "1" ]; then
  if git rev-parse --verify --quiet "refs/tags/$GIT_TAG" >/dev/null; then
    echo "==> $GIT_TAG already exists"
  else
    git tag -a "$GIT_TAG" -m "dsh $VERSION"
    echo "==> tagged $GIT_TAG"
  fi
  if [ "${DSH_PUSH_TAG:-0}" = "1" ]; then
    git push origin "$GIT_TAG"
  else
    echo "    push it with: git push origin $GIT_TAG"
  fi
fi
