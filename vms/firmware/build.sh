#!/bin/bash
export MIX_TARGET=ovcs_base_can_system_rpi4
BASEDIR=$(dirname $0)

cd $BASEDIR/../dashboard
npm install
npm run build
cd ../firmware
mix deps.get
mix firmware
