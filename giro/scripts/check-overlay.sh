#!/usr/bin/env bash
# Fail when this fork differs from upstream outside the Giro overlay.
#
# giro/UPSTREAM_SHA is the oldest acknowledged upstream commit. GitHub's
# Sync fork button merges a newer upstream commit and does not change that
# file. A merge titled "Merge branch 'BaaRai:main' into ..." (or a merge of
# upstream/main) may be the comparison base when the pin is its ancestor and
# every path that differs from its second parent is still inside the overlay.
# Moving the pin remains what rolls that upstream onto the instance.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if [[ ! -f giro/UPSTREAM_SHA ]]; then
  echo "giro/UPSTREAM_SHA is missing." >&2
  exit 1
fi

pin="$(tr -d '[:space:]' < giro/UPSTREAM_SHA)"
if [[ ! "$pin" =~ ^[0-9a-f]{40}$ ]]; then
  echo "giro/UPSTREAM_SHA must be one 40-character commit id." >&2
  exit 1
fi
if ! git cat-file -e "${pin}^{commit}" 2>/dev/null; then
  echo "Commit ${pin} is not in this clone. Fetch the full history." >&2
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

# Newest upstream commit merged on top of the pin. The final diff is what
# rejects a product edit made after that merge, so the failure names that
# edit rather than every upstream file since the old pin. CHECK_INDEX is the
# in-progress sync, which compares the index to the pin file it just wrote.
upstream_base() {
  local merge subject p2
  if ! git merge-base --is-ancestor "$pin" HEAD; then
    printf '%s\n' "$pin"
    return
  fi
  while IFS= read -r merge; do
    [[ -z "$merge" ]] && continue
    subject="$(git log -1 --format=%s "$merge")"
    case "$subject" in
      "Merge branch 'BaaRai:main' into "* | \
        "Merge remote-tracking branch 'upstream/main'"* | \
        "Merge branch 'main' of "*"BaaRai/ARTEX"*) ;;
      *) continue ;;
    esac
    p2="$(git rev-parse -q --verify "${merge}^2" || true)"
    [[ -n "$p2" ]] || continue
    git merge-base --is-ancestor "$pin" "$p2" || continue
    git merge-base --is-ancestor "$p2" HEAD || continue
    printf '%s\n' "$p2"
    return
  done < <(git rev-list --merges --topo-order "${pin}..HEAD")
  printf '%s\n' "$pin"
}

if [[ "${CHECK_INDEX:-}" == 1 ]]; then
  sha="$pin"
else
  sha="$(upstream_base)"
fi

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
if [[ "$sha" != "$pin" ]]; then
  echo "giro/UPSTREAM_SHA still records ${pin}. Moving it is what deploys that upstream."
fi
