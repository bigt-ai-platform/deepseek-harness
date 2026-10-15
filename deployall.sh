#!/usr/bin/env bash
#
# deployall.sh — one release run for the dsh family.
#
#   1. bump      `release:dsh` rewrites the family manifests and commits them
#   2. tag       `dsh-v<version>` — the ref the Desktop packaging workflows accept
#   3. deploy    ./deploy.sh builds + pushes the container images and its own tag
#   4. desktop   dispatch the Desktop installers (`--desktop release` for the two
#                signed self-hosted workflows, `fork` for the hosted unsigned one)
#   5. upload    collect the three installers and copy them to a MinIO bucket
#
# Usage:
#   ./deployall.sh <major|minor|patch|x.y.z> [options]
#   ./deployall.sh 0.2.2
#   ./deployall.sh patch --preset test --windows-signing unsigned
#   ./deployall.sh 0.2.2 --channel latest --watch
#   ./deployall.sh 0.2.2 --upload --minio-bucket dsh-releases --minio-public
#
# Options:
#   --preset production|test      machine preset for both packaging workflows
#                                 (default production)
#   --windows-signing signed|unsigned
#                                 default: signed for production, unsigned for test
#   --channel latest|nightly      installer update channel; latest requires a
#                                 stable version (default: latest when stable)
#   --test-release-id <32 hex>    test preset only; omit to keep the machine default
#   --source-ref master|dsh-v<x>  workflow checkout (default: the tag above)
#   --version-mode default|product|auto|manual
#                                 default: product for production, auto for test
#   --build-version <x.y.z>       required only with --version-mode manual
#   --deploy-version <x.y.z>      DSH_VERSION for deploy.sh; default: deploy.sh derives it
#   --desktop release|fork        release: the two signed self-hosted workflows;
#                                 fork: desktop-fork-package.yml on GitHub-hosted
#                                 runners (unsigned win-x64 + mac-arm64). The two
#                                 production workflows need the registered runners
#                                 dsh-win-package-trial / dsh-mac-package-trial
#   --update-origin <https>       win-x64 mandatory-update policy origin; required
#                                 with --desktop fork
#   --fork-targets <choice>       fork workflow targets (default
#                                 win-x64,mac-arm64,linux-x64)
#   --no-bump / --no-deploy / --no-desktop / --no-push
#   --watch                       follow the packaging run(s) to completion
#
# Upload options (step 5):
#   --upload                      copy the Linux, Windows and macOS installers to MinIO
#   --minio-bucket <name>         target bucket (default dsh-releases)
#   --minio-prefix <path>         object prefix (default deepseek-harness/<version>)
#   --minio-sites eu,us,asia      geo sites to write; the mesh replicates, so one
#                                 site suffices (default eu; all writes every site)
#   --minio-endpoint <url>        one explicit endpoint; overrides --minio-sites
#   --minio-env-file <path>       credentials file (default deploy/env/.env.europa,
#                                 then ~/git/pm/minio/.env.eu); supplies
#                                 S3_ACCESS_KEY/S3_SECRET_KEY or
#                                 MINIO_ROOT_USER/MINIO_ROOT_PASSWORD
#   --minio-public                set anonymous download on the uploaded prefix
#   --linux-artifact <path>       AppImage to publish (default: newest under
#                                 apps/desktop/.desktop-build/.../linux-x64/unsigned-artifacts)
#   --windows-run <id>            reuse an existing packaging run instead of the newest
#   --macos-run <id>
#   -h, --help
#
# Requires: clean tracked worktree, branch master, docker + gh authenticated.
# The Desktop packaging workflows live on master and are only reachable through
# dispatch; they are not triggered by a push or a tag.
set -euo pipefail
cd "$(dirname "$0")"

PROD_WORKFLOW="windows-package.yml"
MAC_WORKFLOW="macos-package.yml"
FORK_WORKFLOW="desktop-fork-package.yml"
BRANCH="master"
MC_IMAGE="ghcr.io/bigt-ai-platform/mc:latest"

PRESET="production"
WINDOWS_SIGNING=""
CHANNEL=""
TEST_RELEASE_ID=""
SOURCE_REF=""
VERSION_MODE=""
BUILD_VERSION=""
DEPLOY_VERSION=""
DO_BUMP=1
DO_DEPLOY=1
DO_DESKTOP=1
DO_PUSH=1
WATCH=0
REQUEST=""
UPLOAD=0
MINIO_BUCKET="dsh-releases"
MINIO_PREFIX=""
MINIO_SITES="eu"
MINIO_ENDPOINT=""
MINIO_ENV_FILE=""
MINIO_PUBLIC=0
LINUX_ARTIFACT=""
WINDOWS_RUN=""
MACOS_RUN=""
DESKTOP_MODE="release"
UPDATE_ORIGIN=""
FORK_RUN=""
FORK_TARGETS="win-x64,mac-arm64,linux-x64"
GH_REPO=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${GREEN}==>${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# Print the header block, which ends at the first non-comment line.
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --preset)          PRESET="${2:?}"; shift 2 ;;
    --windows-signing) WINDOWS_SIGNING="${2:?}"; shift 2 ;;
    --channel)         CHANNEL="${2:?}"; shift 2 ;;
    --test-release-id) TEST_RELEASE_ID="${2:?}"; shift 2 ;;
    --source-ref)      SOURCE_REF="${2:?}"; shift 2 ;;
    --version-mode)    VERSION_MODE="${2:?}"; shift 2 ;;
    --build-version)   BUILD_VERSION="${2:?}"; shift 2 ;;
    --deploy-version)  DEPLOY_VERSION="${2:?}"; shift 2 ;;
    --no-bump)         DO_BUMP=0; shift ;;
    --no-deploy)       DO_DEPLOY=0; shift ;;
    --no-desktop)      DO_DESKTOP=0; shift ;;
    --no-push)         DO_PUSH=0; shift ;;
    --watch)           WATCH=1; shift ;;
    --upload)          UPLOAD=1; shift ;;
    --minio-bucket)    MINIO_BUCKET="${2:?}"; shift 2 ;;
    --minio-prefix)    MINIO_PREFIX="${2:?}"; shift 2 ;;
    --minio-sites)     MINIO_SITES="${2:?}"; shift 2 ;;
    --minio-endpoint)  MINIO_ENDPOINT="${2:?}"; shift 2 ;;
    --minio-env-file)  MINIO_ENV_FILE="${2:?}"; shift 2 ;;
    --minio-public)    MINIO_PUBLIC=1; shift ;;
    --linux-artifact)  LINUX_ARTIFACT="${2:?}"; shift 2 ;;
    --windows-run)     WINDOWS_RUN="${2:?}"; shift 2 ;;
    --macos-run)       MACOS_RUN="${2:?}"; shift 2 ;;
    --desktop)         DESKTOP_MODE="${2:?}"; shift 2 ;;
    --update-origin)   UPDATE_ORIGIN="${2:?}"; shift 2 ;;
    --fork-targets)    FORK_TARGETS="${2:?}"; shift 2 ;;
    --repo)            GH_REPO="${2:?}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    -*)                fail "unknown option '$1' (try --help)" ;;
    *)                 [ -z "$REQUEST" ] || fail "unexpected argument '$1'"
                       REQUEST="$1"; shift ;;
  esac
done

[ -n "$REQUEST" ] || { usage >&2; fail "a version (or major|minor|patch) is required"; }
case "$PRESET" in production|test) ;; *) fail "--preset must be production or test" ;; esac
if [ -z "$WINDOWS_SIGNING" ]; then
  [ "$PRESET" = "production" ] && WINDOWS_SIGNING=signed || WINDOWS_SIGNING=unsigned
fi
case "$WINDOWS_SIGNING" in signed|unsigned) ;; *) fail "--windows-signing must be signed or unsigned" ;; esac
if [ -n "$TEST_RELEASE_ID" ] && ! [[ "$TEST_RELEASE_ID" =~ ^[0-9a-f]{32}$ ]]; then
  fail "--test-release-id must be 32 lowercase hexadecimal characters"
fi
if [ "$DO_DESKTOP" != "1" ] && [ "$UPLOAD" = "1" ]; then
  fail "--upload collects the Windows and macOS artifacts, so it needs the Desktop dispatch; drop --no-desktop"
fi
for site in $(echo "$MINIO_SITES" | tr ',' ' '); do
  case "$site" in all|eu|us|asia) ;; *) fail "--minio-sites entries must be eu, us or asia (or all)" ;; esac
done
case "$DESKTOP_MODE" in release|fork) ;; *) fail "--desktop must be release or fork" ;; esac
if [ -n "$UPDATE_ORIGIN" ] && ! [[ "$UPDATE_ORIGIN" =~ ^https://[^/]+/?$ ]]; then
  fail "--update-origin must be an https origin such as https://download.example.com"
fi
if [ "$DESKTOP_MODE" = "fork" ] && [ "$DO_DESKTOP" = "1" ] && [ -z "$UPDATE_ORIGIN" ]; then
  fail "--desktop fork needs --update-origin <https origin>: the win-x64 build embeds the mandatory-update policy origin"
fi
# The fork workflow's `targets` input is a fixed choice list.
case "$FORK_TARGETS" in
  win-x64,mac-arm64,linux-x64|win-x64,mac-arm64,mac-x64,linux-x64|win-x64|mac-arm64|mac-x64|linux-x64) ;;
  *) fail "--fork-targets must be one of the workflow's choices (e.g. win-x64,mac-arm64,linux-x64)" ;;
esac

# ── preconditions ──────────────────────────────────────────────────────────
step "Checking preconditions"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a git worktree"
git diff --quiet && git diff --cached --quiet \
  || fail "tracked worktree is not clean; commit or stash first"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || fail "on '$CURRENT_BRANCH'; a release runs from $BRANCH"
command -v gh >/dev/null 2>&1 || fail "gh is required for the Desktop dispatch"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

# Resolve the GitHub repository from `origin` once. A checkout with an `upstream`
# remote makes gh guess between them, so every call passes --repo explicitly.
if [ -z "$GH_REPO" ]; then
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN_URL" in
    *github.com[:/]*)
      GH_REPO="${ORIGIN_URL#*github.com}"
      GH_REPO="${GH_REPO#[:/]}"
      GH_REPO="${GH_REPO%.git}"
      ;;
  esac
fi
[ -n "$GH_REPO" ] || fail "cannot resolve the GitHub repo from origin; pass --repo <owner/name>"
echo "    github repo $GH_REPO"
if [ "$DO_DEPLOY" = "1" ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required for deploy.sh"
  docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"
fi
if [ "$DO_PUSH" = "1" ]; then
  git fetch origin "$BRANCH" --quiet || fail "cannot fetch origin/$BRANCH"
  LOCAL="$(git rev-parse HEAD)"; REMOTE="$(git rev-parse "origin/$BRANCH")"
  if [ "$LOCAL" != "$REMOTE" ] && ! git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
    fail "origin/$BRANCH has moved; merge it before releasing"
  fi
fi

# ── 1. version bump ────────────────────────────────────────────────────────
if [ "$DO_BUMP" = "1" ]; then
  step "Bumping the dsh family: release:dsh $REQUEST"
  pnpm run release:dsh -- "$REQUEST"
else
  step "Skipping the bump (--no-bump); using the manifests as they are"
fi

VERSION="$(node -p "require('./package.json').version")"
[ -n "$VERSION" ] || fail "could not read the workspace version"
if [[ "$REQUEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ && "$VERSION" != "$REQUEST" ]]; then
  fail "manifests say $VERSION but $REQUEST was requested"
fi

# `latest` packages reject prereleases, so a prerelease releases on nightly.
STABLE=1; [[ "$VERSION" == *-* ]] && STABLE=0
if [ -z "$CHANNEL" ]; then
  if [ "$STABLE" = "1" ]; then CHANNEL=latest; else CHANNEL=nightly; fi
fi
case "$CHANNEL" in latest|nightly) ;; *) fail "--channel must be latest or nightly" ;; esac
if [ "$CHANNEL" = "latest" ] && [ "$STABLE" = "0" ]; then
  fail "the latest channel requires a stable version; $VERSION is a prerelease"
fi
if [ -z "$VERSION_MODE" ]; then
  if [ "$PRESET" = "production" ]; then VERSION_MODE=product; else VERSION_MODE=auto; fi
fi
if [ "$VERSION_MODE" = "manual" ] && [ -z "$BUILD_VERSION" ]; then
  fail "--build-version is required with --version-mode manual"
fi
echo "    version $VERSION   preset $PRESET   channel $CHANNEL   version-mode $VERSION_MODE   windows $WINDOWS_SIGNING"

GIT_TAG="dsh-v$VERSION"

# ── 2. publish the commit and the source tag ───────────────────────────────
if [ "$DO_PUSH" = "1" ]; then
  step "Pushing $BRANCH and $GIT_TAG"
  git push origin "$BRANCH"
  if git rev-parse --verify --quiet "refs/tags/$GIT_TAG" >/dev/null; then
    if [ "$(git rev-parse "$GIT_TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
      fail "$GIT_TAG already exists on a different commit; bump the version instead"
    fi
    info "$GIT_TAG already exists on HEAD"
  else
    git tag -a "$GIT_TAG" -m "dsh $VERSION"
  fi
  git push origin "$GIT_TAG"
else
  step "Skipping the push (--no-push)"
  git rev-parse --verify --quiet "refs/tags/$GIT_TAG" >/dev/null || info "tag $GIT_TAG is not created locally either"
fi

# ── 3. Desktop installers ──────────────────────────────────────────────────
# Dispatched before the images so the long CI build overlaps deploy.sh; the
# artifacts are only consumed at step 5.
[ -n "$SOURCE_REF" ] || SOURCE_REF="$GIT_TAG"
if [ "$DO_DESKTOP" != "1" ]; then
  step "Skipping the Desktop dispatch (--no-desktop)"
else

[ -n "$SOURCE_REF" ] || SOURCE_REF="$GIT_TAG"
if [ "$SOURCE_REF" != "master" ] && [ "$SOURCE_REF" != "$GIT_TAG" ]; then
  fail "--source-ref must be master or $GIT_TAG for version $VERSION"
fi

# Both workflows validate source_ref against the checked-out package.json, so a
# tag that has not reached origin cannot be selected.
if [ "$SOURCE_REF" != "master" ] && [ "$DO_PUSH" = "1" ]; then
  git ls-remote --exit-code --tags origin "refs/tags/$SOURCE_REF" >/dev/null 2>&1 \
    || fail "$SOURCE_REF is not on origin yet"
fi

dispatch() { # workflow extra-field...
  local workflow="$1"; shift
  local -a fields=(
    -f "preset=$PRESET"
    -f "source_ref=$SOURCE_REF"
    -f "update_channel=$CHANNEL"
    -f "version_mode=$VERSION_MODE"
  )
  if [ -n "$BUILD_VERSION" ] && [ "$VERSION_MODE" = "manual" ]; then
    fields+=(-f "build_version=$BUILD_VERSION")
  fi
  if [ -n "$TEST_RELEASE_ID" ]; then
    fields+=(-f "test_release_id=$TEST_RELEASE_ID")
  fi
  fields+=("$@")
  gh workflow run "$workflow" --repo "$GH_REPO" --ref "$BRANCH" "${fields[@]}"
}

if [ "$DESKTOP_MODE" = "fork" ]; then
  step "Dispatching Package Desktop (fork) · unsigned installers ($FORK_WORKFLOW)"
  gh workflow run "$FORK_WORKFLOW" --repo "$GH_REPO" --ref "$BRANCH" \
    -f "targets=$FORK_TARGETS" -f "update_origin=$UPDATE_ORIGIN"
  pending_fork() {
    local id=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      id="$(gh run list --repo "$GH_REPO" --workflow "$FORK_WORKFLOW" --branch "$BRANCH" --event workflow_dispatch \
        --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
      if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
      sleep 3
    done
    return 1
  }
  FORK_RUN="$(pending_fork || true)"
  info "fork packaging run: ${FORK_RUN:-unknown}"
else
  step "Dispatching Package Desktop · Windows ($PROD_WORKFLOW)"
  dispatch "$PROD_WORKFLOW" -f "signing=$WINDOWS_SIGNING"

  step "Dispatching Package Desktop · macOS ($MAC_WORKFLOW)"
  dispatch "$MAC_WORKFLOW" -f "skip_notarization=false"
fi

# The dispatch registers the run asynchronously, so poll for its id.
pending_run() { # workflow -> newest dispatch run id
  local id=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    id="$(gh run list --repo "$GH_REPO" --workflow "$1" --branch "$BRANCH" --event workflow_dispatch \
      --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
    sleep 3
  done
  return 1
}
if [ "$DESKTOP_MODE" = "release" ]; then
  [ -n "$WINDOWS_RUN" ] || WINDOWS_RUN="$(pending_run "$PROD_WORKFLOW" || true)"
  [ -n "$MACOS_RUN" ] || MACOS_RUN="$(pending_run "$MAC_WORKFLOW" || true)"
  info "windows run: ${WINDOWS_RUN:-unknown}"
  info "macos run:   ${MACOS_RUN:-unknown}"
  fi
fi

# ── 4. container images ────────────────────────────────────────────────────
if [ "$DO_DEPLOY" = "1" ]; then
  step "Deploying the container images (deploy.sh)"
  if [ -n "$DEPLOY_VERSION" ]; then
    DSH_VERSION="$DEPLOY_VERSION" ./deploy.sh
  else
    ./deploy.sh
  fi
else
  step "Skipping deploy.sh (--no-deploy)"
fi

# Wait when asked to follow, and whenever the artifacts are needed.
if [ "$DO_DESKTOP" = "1" ] && { [ "$WATCH" = "1" ] || [ "$UPLOAD" = "1" ]; }; then
  step "Waiting for the packaging run(s)"
  if [ "$DESKTOP_MODE" = "fork" ]; then
    [ -n "$FORK_RUN" ] || fail "fork packaging run id unknown; open the Actions tab"
    gh run watch "$FORK_RUN" --repo "$GH_REPO" --exit-status --interval 30 >/dev/null \
      || fail "fork packaging run $FORK_RUN did not succeed"
  else
    [ -n "$WINDOWS_RUN" ] || fail "windows run id unknown; pass --windows-run <id>"
    [ -n "$MACOS_RUN" ] || fail "macos run id unknown; pass --macos-run <id>"
    gh run watch "$WINDOWS_RUN" --repo "$GH_REPO" --exit-status --interval 30 >/dev/null || fail "windows run $WINDOWS_RUN did not succeed"
    gh run watch "$MACOS_RUN" --repo "$GH_REPO" --exit-status --interval 30 >/dev/null || fail "macos run $MACOS_RUN did not succeed"
  fi
fi

# ── 5. MinIO upload ────────────────────────────────────────────────────────
if [ "$UPLOAD" = "1" ]; then
  step "Uploading the installers to MinIO"
  command -v docker >/dev/null 2>&1 || fail "docker is required for the MinIO upload"
  docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"

  [ -n "$MINIO_PREFIX" ] || MINIO_PREFIX="deepseek-harness/$VERSION"
  cred() { grep -m1 "^$1=" "$MINIO_ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d "\"' " || true; }
  if [ -z "$MINIO_ENV_FILE" ]; then
    for candidate in deploy/env/.env.europa "$HOME/git/pm/minio/.env.eu"; do
      if [ -f "$candidate" ]; then MINIO_ENV_FILE="$candidate"; break; fi
    done
  fi
  [ -n "$MINIO_ENV_FILE" ] && [ -f "$MINIO_ENV_FILE" ] \
    || fail "no MinIO credentials file; pass --minio-env-file <path>"
  AK="${S3_ACCESS_KEY:-$(cred S3_ACCESS_KEY)}"
  [ -n "$AK" ] || AK="$(cred MINIO_ROOT_USER)"
  SK="${S3_SECRET_KEY:-$(cred S3_SECRET_KEY)}"
  [ -n "$SK" ] || SK="$(cred MINIO_ROOT_PASSWORD)"
  [ -n "$AK" ] && [ -n "$SK" ] \
    || fail "$MINIO_ENV_FILE carries no S3_ACCESS_KEY/S3_SECRET_KEY or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD"

  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/linux" "$STAGE/windows" "$STAGE/macos"

  if [ -n "$LINUX_ARTIFACT" ]; then
    [ -f "$LINUX_ARTIFACT" ] || fail "--linux-artifact $LINUX_ARTIFACT is not a file"
  else
    LINUX_ARTIFACT="$(ls -1t apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/*.AppImage 2>/dev/null | head -1 || true)"
  fi
  [ -n "$LINUX_ARTIFACT" ] && [ -f "$LINUX_ARTIFACT" ] \
    || fail "no Linux AppImage; build it (pnpm --dir apps/desktop run package:linux:x64:unsigned) or pass --linux-artifact"
  cp "$LINUX_ARTIFACT" "$STAGE/linux/"
  info "linux:   $(basename "$LINUX_ARTIFACT")"

  if [ "$DESKTOP_MODE" = "fork" ]; then
    gh run download "$FORK_RUN" --repo "$GH_REPO" --dir "$STAGE/windows" --pattern 'desktop-win-x64-*' \
      || fail "run $FORK_RUN carries no desktop-win-x64 artifact"
    gh run download "$FORK_RUN" --repo "$GH_REPO" --dir "$STAGE/macos" --pattern 'desktop-mac-*' \
      || fail "run $FORK_RUN carries no desktop-mac artifact"
  else
    gh run download "$WINDOWS_RUN" --repo "$GH_REPO" --dir "$STAGE/windows" --pattern 'windows-x64-*' \
      || fail "run $WINDOWS_RUN carries no windows-x64 artifact"
    gh run download "$MACOS_RUN" --repo "$GH_REPO" --dir "$STAGE/macos" --pattern 'macos-arm64-*' \
      || fail "run $MACOS_RUN carries no macos-arm64 artifact"
  fi
  info "windows: $(find "$STAGE/windows" -type f | wc -l) file(s)"
  info "macos:   $(find "$STAGE/macos" -type f | wc -l) file(s)"

  endpoint_for_site() {
    case "$1" in
      eu)   echo "https://minio-s1001.bigt.ai" ;;
      us)   echo "https://minio-us1001.bigt.ai" ;;
      asia) echo "https://minio-hk1002.bigt.ai" ;;
      *) return 1 ;;
    esac
  }
  if [ -n "$MINIO_ENDPOINT" ]; then
    SITES="custom"
  elif [ "$MINIO_SITES" = "all" ]; then
    SITES="eu us asia"
  else
    SITES="$(echo "$MINIO_SITES" | tr ',' ' ')"
  fi

  for site in $SITES; do
    if [ "$site" = "custom" ]; then
      EP="$MINIO_ENDPOINT"
    else
      EP="$(endpoint_for_site "$site")" || fail "unknown site '$site' (eu, us, asia)"
    fi
    echo "==> $MINIO_BUCKET/$MINIO_PREFIX <- $EP"
    docker run --rm \
      -e EP="$EP" -e AK="$AK" -e SK="$SK" -e B="$MINIO_BUCKET" -e P="$MINIO_PREFIX" -e PUB="$MINIO_PUBLIC" \
      -v "$STAGE:/data:ro" --entrypoint sh "$MC_IMAGE" -c '
        set -e
        mc alias set r "$EP" "$AK" "$SK" >/dev/null
        mc mb --ignore-existing "r/$B" >/dev/null
        mc cp --recursive /data/ "r/$B/$P/" >/dev/null
        if [ "$PUB" = "1" ]; then mc anonymous set download "r/$B/$P" >/dev/null; fi
        mc ls --recursive "r/$B/$P/"
      '
  done
  info "uploaded to $MINIO_BUCKET/$MINIO_PREFIX on: $SITES"
fi

echo
if [ "$DO_DESKTOP" = "1" ]; then
  echo -e "${GREEN}Release $VERSION dispatched.${NC}"
else
  echo -e "${GREEN}Release $VERSION finished.${NC}"
fi
echo "  source ref:   $SOURCE_REF"
if [ "$DESKTOP_MODE" = "fork" ]; then
  echo "  desktop:      gh run view ${FORK_RUN:-<id>} --repo $GH_REPO   (fork, unsigned, hosted runners)"
else
  echo "  windows:      gh run view ${WINDOWS_RUN:-<id>} --repo $GH_REPO"
  echo "  macos:        gh run view ${MACOS_RUN:-<id>} --repo $GH_REPO"
fi
if [ "$UPLOAD" = "1" ]; then echo "  minio:        $MINIO_BUCKET/$MINIO_PREFIX"; fi
if [ "$DESKTOP_MODE" = "release" ]; then
  echo "  publish next: Publish Desktop COS → Run workflow (package_run_id from the run URL)"
fi
