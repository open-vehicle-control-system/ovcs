#!/bin/sh
export MIX_TARGET=ovcs_infotainment_system_rpi4
BASEDIR=$(dirname $0)

cd $BASEDIR/../dashboard
npm install
npm run build
cd ../firmware
pwd
mix deps.get
mix firmware