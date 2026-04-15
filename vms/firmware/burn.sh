#!/bin/bash
: "${MIX_TARGET:=ovcs_base_can_system_rpi4}"
export MIX_TARGET

mix deps.get
mix burn
