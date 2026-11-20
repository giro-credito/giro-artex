#!/usr/bin/env bash
# Replay giro/patches/*.patch onto a clean tree. File names sort in apply order.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

shopt -s nullglob
patches=(giro/patches/*.patch)
if ((${#patches[@]} == 0)); then
  echo "No Giro patches."
  exit 0
fi

args=()
if [[ "${1:-}" == "--check" ]]; then
  args=(--check)
elif [[ $# -gt 0 ]]; then
  echo "Usage: apply-patches.sh [--check]" >&2
  exit 2
fi

git apply "${args[@]}" "${patches[@]}"
if [[ ${#args[@]} -eq 0 ]]; then
  echo "Applied ${#patches[@]} patch(es)."
else
  echo "${#patches[@]} patch(es) apply cleanly."
fi
