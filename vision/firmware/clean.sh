#!/bin/bash
# Remove build artifacts that commonly get stale after switching VEHICLE or
# upgrading the toolchain or Nerves system. Idempotent.
set -e
cd "$(dirname "$0")"

echo "→ vision/firmware"
rm -rf _build deps

echo "→ vision/api"
(cd ../api && rm -rf _build deps priv/static)

echo "→ vision/core"
(cd ../core && rm -rf _build deps)

echo "→ vision/rust"
(cd ../rust && rm -rf target)

echo "→ vision/dashboard"
(cd ../dashboard && rm -rf node_modules dist)
