#!/bin/bash
# Remove build artifacts that commonly get stale after switching VEHICLE or
# upgrading the toolchain. Idempotent — safe to run any time.
set -e
cd "$(dirname "$0")"

echo "→ vms/firmware"
rm -rf _build deps

echo "→ vms/api"
(cd ../api && rm -rf _build deps priv/static/assets priv/static/index.html)

echo "→ vms/core"
(cd ../core && rm -rf _build deps)

echo "→ vms/dashboard"
(cd ../dashboard && rm -rf node_modules dist)
