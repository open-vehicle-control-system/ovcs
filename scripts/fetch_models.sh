#!/usr/bin/env bash
#
# Fetch the detection models the perception bridge uses, verify them,
# and put them where the vehicle packages expect them.
#
#   mise run fetch-models          # fetch anything missing or corrupt
#   mise run fetch-models -- -f    # re-fetch everything
#
# ## Why these are not in the repository
#
# OVCS is MIT licensed. YOLOv8's weights are Ultralytics AGPL-3.0, and
# the two do not compose in that direction: MIT tells downstream users
# they may use this without source-disclosure obligations, which AGPL
# does not permit anyone to grant. So the weights are fetched rather
# than vendored, and this script prints the licence of each one so the
# choice is made knowingly rather than inherited from a git clone.
#
# The cost is real and worth stating: a firmware build is no longer
# reproducible offline without running this first. `priv/models/README.md`
# used to argue the other way. The licence is why it changed.
#
# Nothing breaks when a model is absent. Both `Inference.Hailo` and
# `Inference.Dnn` log once and answer `{:error, :unavailable}`, and the
# stereo depth pipeline runs on regardless — losing detections is
# acceptable, taking depth down with it is not.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/models.tsv"

FORCE=0
while getopts "fh" opt; do
  case "$opt" in
    f) FORCE=1 ;;
    h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done

ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
info() { printf '\033[1;36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }

command -v curl    >/dev/null || { fail "curl is required"; exit 1; }
command -v sha256sum >/dev/null || { fail "sha256sum is required"; exit 1; }

fetched=0
skipped=0
failed=0

# Tab-separated; comments and blank lines ignored. IFS is set to a tab
# only, so the licence column may contain spaces.
while IFS=$'\t' read -r dest sha licence url; do
  case "${dest// /}" in ''|'#'*) continue ;; esac
  [ -n "${url:-}" ] || { fail "malformed manifest line for '$dest'"; failed=$((failed + 1)); continue; }

  target="$REPO/$dest"
  name="$(basename "$dest")"

  if [ "$FORCE" -eq 0 ] && [ -f "$target" ]; then
    if [ "$(sha256sum "$target" | cut -d' ' -f1)" = "$sha" ]; then
      ok "$name already present and verified"
      skipped=$((skipped + 1))
      continue
    fi
    warn "$name is present but does not match its checksum — re-fetching"
  fi

  info "Fetching $name"
  printf '    licence: %s\n' "$licence"
  printf '    from:    %s\n' "$url"

  mkdir -p "$(dirname "$target")"
  # To a temporary file first: a half-downloaded model that happens to
  # exist is worse than no model, because the backends check for
  # presence before they try to load.
  tmp="$(mktemp "${TMPDIR:-/tmp}/ovcs-model.XXXXXX")"
  if ! curl -fSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    fail "download failed: $url"
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi

  actual="$(sha256sum "$tmp" | cut -d' ' -f1)"
  if [ "$actual" != "$sha" ]; then
    fail "checksum mismatch for $name"
    printf '      expected %s\n      got      %s\n' "$sha" "$actual" >&2
    rm -f "$tmp"
    failed=$((failed + 1))
    continue
  fi

  mv "$tmp" "$target"
  chmod 644 "$target"
  ok "$name verified and installed"
  fetched=$((fetched + 1))
done < "$MANIFEST"

echo
printf 'Fetched %d, already present %d, failed %d.\n' "$fetched" "$skipped" "$failed"
[ "$failed" -eq 0 ] || exit 1
