#!/usr/bin/env bash
#
# Clone the sideloaded libraries listed in scripts/libraries.tsv into
# libraries/ at their pinned commits, or check that the clones match.
#
#   mise run libraries          # clone missing libraries at their pin
#   mise run libraries-check    # fail when a clone is not at its pin
#
# An existing clone is never moved, so local work in it survives; clone
# reports it and check fails on it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/libraries.tsv"
MODE="${1:-clone}"

case "$MODE" in
  clone | check) ;;
  *) echo "usage: $0 [clone|check]" >&2; exit 2 ;;
esac

mismatches=0
while IFS=$'\t' read -r repository commit; do
  case "$repository" in '' | '#'*) continue ;; esac
  name="${repository#*/}"
  dir="$REPO/libraries/$name"

  if [ ! -d "$dir/.git" ]; then
    if [ "$MODE" = check ]; then
      echo "✗ $name is not cloned"
      mismatches=$((mismatches + 1))
      continue
    fi
    echo "→ cloning $name at ${commit:0:7}"
    git clone --quiet "https://github.com/$repository.git" "$dir"
    git -C "$dir" checkout --quiet --detach "$commit"
    continue
  fi

  head="$(git -C "$dir" rev-parse HEAD)"
  if [ "$head" = "$commit" ]; then
    echo "✓ $name at ${commit:0:7}"
  else
    echo "✗ $name at ${head:0:7}, pinned at ${commit:0:7}"
    mismatches=$((mismatches + 1))
  fi
done < "$MANIFEST"

if [ "$MODE" = check ] && [ "$mismatches" -gt 0 ]; then
  exit 1
fi
