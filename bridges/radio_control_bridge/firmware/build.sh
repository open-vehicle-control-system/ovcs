#!/bin/bash
export MIX_TARGET=ovcs_bridge_system_rpi3a

BASEDIR=$(dirname $0)

cd $BASEDIR/../firmware

mix deps.get
mix firmware


