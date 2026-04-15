#!/bin/bash
: "${MIX_TARGET:=ovcs_base_can_system_rpi4}"
export MIX_TARGET

cd ../dashboard
npm install
npm run build
cd ../firmware
mix deps.get
mix firmware
