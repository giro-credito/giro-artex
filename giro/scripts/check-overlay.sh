#!/usr/bin/env bash
# Fail when this fork differs from the pinned upstream commit outside the Giro overlay.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if [[ ! -f giro/UPSTREAM_SHA ]]; then
  echo "giro/UPSTREAM_SHA is missing." >&2
  exit 1
fi

sha="$(tr -d '[:space:]' < giro/UPSTREAM_SHA)"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "giro/UPSTREAM_SHA must be one 40-character commit id." >&2
  exit 1
fi
if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
  echo "Commit ${sha} is not in this clone. Fetch the full history." >&2
  exit 1
fi

allowed() {
  case "$1" in
    giro | giro/* | .github/workflows/giro-overlay.yml | .github/workflows/giro-deploy.yml)
      return 0
      ;;
  esac
  return 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ "${CHECK_INDEX:-}" == 1 ]]; then
  git diff --cached --name-only "$sha" >"$tmp"
else
  {
    git diff --name-only "$sha" HEAD
    git diff --name-only HEAD
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } >"$tmp"
fi

bad=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if ! allowed "$path"; then
    bad+=("$path")
  fi
done < <(sort -u "$tmp")

if ((${#bad[@]} > 0)); then
  echo "Giro changes belong under giro/, or in the two giro workflow files." >&2
  echo "These paths differ from ${sha}:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  exit 1
fi

echo "Overlay matches ${sha}."
