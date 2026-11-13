#!/usr/bin/env bash
#
# Compile the simulator runner for the host. Used by
# `./ovcs run <vehicle> --simulate` before it spawns the runner.
#
set -euo pipefail
cd "$(dirname "$0")"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

step "Fetching Mix dependencies"
mix deps.get

step "Compiling for host"
mix compile
