#!/usr/bin/env bash
#
# Sync this fork with upstream and rebase the working branch.
#
#   1. Fetches deepseek-ai/deepseek-harness (remote "upstream").
#   2. Fast-forwards local "master" to upstream master and pushes it to
#      the fork ("origin"), so the fork's master mirrors upstream.
#   3. Rebases "dai" onto the updated master.
#
# Ends on "dai". If the rebase stops on a conflict, resolve it and run
# `git rebase --continue` (or `git rebase --abort` to cancel).
set -euo pipefail

UPSTREAM_NAME="upstream"
UPSTREAM_URL="git@github.com:deepseek-ai/deepseek-harness.git"
UPSTREAM_BRANCH="master"
FORK_MASTER="master"
WORK_BRANCH="dai"

if git remote get-url "$UPSTREAM_NAME" >/dev/null 2>&1; then
  CURRENT_URL="$(git remote get-url "$UPSTREAM_NAME")"
  if [ "$CURRENT_URL" != "$UPSTREAM_URL" ]; then
    echo "error: remote '$UPSTREAM_NAME' points at '$CURRENT_URL', expected '$UPSTREAM_URL'" >&2
    exit 1
  fi
else
  git remote add "$UPSTREAM_NAME" "$UPSTREAM_URL"
fi

git diff --quiet && git diff --cached --quiet \
  || { echo "error: tracked worktree is not clean; commit or stash first" >&2; exit 1; }

git fetch "$UPSTREAM_NAME" --prune
git fetch origin --prune
git rev-parse --verify --quiet "$UPSTREAM_NAME/$UPSTREAM_BRANCH" >/dev/null \
  || { echo "error: no such ref $UPSTREAM_NAME/$UPSTREAM_BRANCH" >&2; exit 1; }

ORIGIN_DAI="$(git rev-parse --verify --quiet "origin/$WORK_BRANCH" || true)"

git checkout "$FORK_MASTER"
git merge --ff-only "$UPSTREAM_NAME/$UPSTREAM_BRANCH"
git push origin "$FORK_MASTER"

git checkout "$WORK_BRANCH"
git rebase "$FORK_MASTER"

echo "master now at $(git rev-parse --short "$FORK_MASTER"); dai rebased onto it."
if [ -n "$ORIGIN_DAI" ]; then
  echo "Publish the rebased branch with:"
  echo "  git push --force-with-lease=$WORK_BRANCH:$ORIGIN_DAI"
fi
