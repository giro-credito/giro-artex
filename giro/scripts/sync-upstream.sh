#!/usr/bin/env bash
# Merge BaaRai/ARTEX into the current branch and move giro/UPSTREAM_SHA with it.
# Does not push.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

upstream_https="https://github.com/BaaRai/ARTEX.git"
upstream_ssh="git@github.com:BaaRai/ARTEX.git"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Worktree is dirty. Commit or stash before syncing." >&2
  exit 1
fi

current="$(git remote get-url upstream 2>/dev/null || true)"
if [[ -z "$current" ]]; then
  git remote add upstream "$upstream_https"
elif [[ "$current" != "$upstream_https" && "$current" != "$upstream_ssh" ]]; then
  echo "upstream remote is ${current}. Expected BaaRai/ARTEX." >&2
  exit 1
fi

git fetch upstream
ref="${1:-upstream/main}"
git rev-parse --verify "${ref}^{commit}" >/dev/null

if [[ "$(git rev-list --count "HEAD..${ref}")" == "0" ]]; then
  echo "Already contains ${ref}."
  exit 0
fi

if ! git merge --no-commit --no-ff "$ref"; then
  echo "Merge stopped with conflicts:" >&2
  git diff --name-only --diff-filter=U >&2 || true
  echo "A conflict outside giro/ means the merge should be aborted: git merge --abort" >&2
  echo "When every conflict is under giro/, resolve it and finish with:" >&2
  echo "  git rev-parse ${ref} > giro/UPSTREAM_SHA" >&2
  echo "  git add giro/UPSTREAM_SHA" >&2
  echo "  CHECK_INDEX=1 giro/scripts/check-overlay.sh" >&2
  echo "  git commit --no-edit" >&2
  echo "  giro/scripts/check-overlay.sh" >&2
  exit 1
fi

git rev-parse "${ref}^{commit}" >giro/UPSTREAM_SHA
git add giro/UPSTREAM_SHA
CHECK_INDEX=1 bash giro/scripts/check-overlay.sh
git commit --no-edit
bash giro/scripts/check-overlay.sh
echo "Merged ${ref} as $(git rev-parse --short HEAD). Not pushed."
