#!/usr/bin/env bash
#
# Clone the sideloaded libraries listed in scripts/libraries.tsv into
# libraries/ at their pinned commits, or check that the clones match.
#
#   mise run libraries          # clone missing libraries at their pin
#   mise run libraries-check    # fail when a clone is not at its pin
#   mise run libraries-sync     # also move clean clones to their pin
#
# clone never moves an existing clone, so local work in it survives;
# clone reports it and check fails on it. sync is for a checkout nobody
# edits, such as a vehicle's deps/ovcs: it moves clean clones and fails
# on a clone with local changes or unpushed commits, leaving it where it is.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/libraries.tsv"
MODE="${1:-clone}"

case "$MODE" in
  clone | check | sync) ;;
  *) echo "usage: $0 [clone|check|sync]" >&2; exit 2 ;;
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
  elif [ "$MODE" = sync ]; then
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      echo "✗ $name has local changes; left at ${head:0:7}, pinned at ${commit:0:7}"
      mismatches=$((mismatches + 1))
      continue
    fi
    if [ -n "$(git -C "$dir" rev-list HEAD --not --remotes)" ]; then
      echo "✗ $name has local commits not on its remote; left at ${head:0:7}, pinned at ${commit:0:7}"
      mismatches=$((mismatches + 1))
      continue
    fi
    echo "→ moving $name from ${head:0:7} to ${commit:0:7}"
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$dir" fetch --quiet origin
    git -C "$dir" checkout --quiet --detach "$commit"
  else
    echo "✗ $name at ${head:0:7}, pinned at ${commit:0:7}"
    mismatches=$((mismatches + 1))
  fi
done < "$MANIFEST"

if [ "$MODE" != clone ] && [ "$mismatches" -gt 0 ]; then
  exit 1
fi
