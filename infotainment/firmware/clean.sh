#!/bin/bash
# Remove build artifacts that commonly get stale after switching VEHICLE,
# upgrading Flutter, or changing the Nerves target. Idempotent.
set -e
cd "$(dirname "$0")"

echo "→ infotainment/firmware"
rm -rf _build deps

echo "→ infotainment/api"
(cd ../api && rm -rf _build deps)

echo "→ infotainment/core"
(cd ../core && rm -rf _build deps)

echo "→ infotainment/dashboard (Flutter)"
(
  cd ../dashboard
  rm -rf .dart_tool build linux/flutter/ephemeral \
    .flutter-plugins .flutter-plugins-dependencies
  if command -v flutter >/dev/null; then
    flutter clean >/dev/null 2>&1 || true
  fi
)

echo "→ nerves_flutter_support cache"
rm -rf "${HOME}/.cache/nerves_flutter_support"
