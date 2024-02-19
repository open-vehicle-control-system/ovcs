#!/bin/sh
export MIX_TARGET=ovcs_infotainment_system_rpi4
cd ./ovcs_infotainment_frontend
npm install
npm run build
cd ../ovcs_infotainment_firmware
mix deps.get
mix firmware