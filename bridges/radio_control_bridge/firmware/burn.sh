#!/bin/bash
export MIX_TARGET=ovcs_base_can_system_rpi3a
BASEDIR=$(dirname $0)

cd $BASEDIR/../firmware

mix burn
