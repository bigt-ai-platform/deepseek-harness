#!/usr/bin/env bash
# scripts/docker-keep-latest.sh — keep only the latest tag per variant for
# local deepseek-harness builds.
#
# `deploy.sh` tags each image variant twice: `<repo>:v<version>[<suffix>]` and
# `<repo>:latest[<suffix>]` (suffix "" for min, "-full" for full). The versioned
# tags stay locally forever and a dev host accumulates ~1 GB (min) / ~3 GB
# (full) per release. Pushed tags live in the registry, so the local copies are
# disposable.
#
#   ./scripts/docker-keep-latest.sh                     # deepseek-harness
#   ./scripts/docker-keep-latest.sh --keep latest,latest-full,v0.2.3-full
#   ./scripts/docker-keep-latest.sh --prune             # also drop dangling
#   ./scripts/docker-keep-latest.sh --dry-run           # print what would go
#
# Repositories are matched by their LAST path component, so
# `deepseek-harness`, `ghcr.io/bigt-ai-platform/deepseek-harness` and any
# custom image repo are handled by naming the family once. An image referenced
# by an existing (even stopped) container is kept and reported.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

KEEP_TAGS="${KEEP_TAGS:-latest,latest-full}"
PRUNE=0
DRY_RUN=0
REPOS=()

usages() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)    KEEP_TAGS="${2:?--keep needs a comma-separated tag list}"; shift 2 ;;
        --prune)   PRUNE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usages; exit 0 ;;
        -*) echo -e "${RED}unknown option: $1${NC}" >&2; usages >&2; exit 2 ;;
        *)  REPOS+=("$1"); shift ;;
    esac
done

[ ${#REPOS[@]} -eq 0 ] && REPOS=(deepseek-harness)

command -v docker >/dev/null 2>&1 || { echo -e "${RED}docker not found${NC}" >&2; exit 1; }

# Image IDs referenced by any container (running or exited) must survive.
in_use() { [ -n "$(docker ps -aq --filter "ancestor=$1" 2>/dev/null)" ]; }

is_kept() {
    local tag="$1" keep
    for keep in ${KEEP_TAGS//,/ }; do
        [ "$tag" = "$keep" ] && return 0
    done
    return 1
}

removed=0
kept_names=0
skipped=0

while IFS=$'\t' read -r repo tag id; do
    [ -z "$repo" ] || [ "$repo" = "<none>" ] && continue
    [ "$tag" = "<none>" ] && continue

    base="${repo##*/}"
    match=0
    for r in "${REPOS[@]}"; do [ "$r" = "$base" ] && match=1 && break; done
    [ "$match" -eq 1 ] || continue

    if is_kept "$tag"; then
        echo -e "${GREEN}keep${NC}    ${repo}:${tag}"
        kept_names=$((kept_names + 1))
        continue
    fi

    if in_use "$id"; then
        echo -e "${YELLOW}in use${NC}  ${repo}:${tag} (container references ${id:0:12}, not removed)"
        skipped=$((skipped + 1))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would rm ${repo}:${tag} (${id:0:12})"
        removed=$((removed + 1))
        continue
    fi

    if docker rmi "${repo}:${tag}" >/dev/null 2>&1; then
        echo -e "${RED}rm${NC}      ${repo}:${tag} (${id:0:12})"
        removed=$((removed + 1))
    else
        echo -e "${YELLOW}failed${NC}  ${repo}:${tag} (${id:0:12})"
        skipped=$((skipped + 1))
    fi
done < <(docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' --no-trunc)

if [ "$PRUNE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo -e "${GREEN}--- docker image prune (dangling) ---${NC}"
    docker image prune -f
fi

verb=removed
[ "$DRY_RUN" -eq 1 ] && verb=would-remove
echo -e "${GREEN}=== ${verb} ${removed} tag(s); kept ${kept_names}; skipped ${skipped} ===${NC}"
