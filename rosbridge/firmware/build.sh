#!/bin/bash
export MIX_TARGET=ovcs_vms_system_rpi4
BASEDIR=$(dirname $0)

cd $BASEDIR/../firmware
mix deps.get
mix firmware