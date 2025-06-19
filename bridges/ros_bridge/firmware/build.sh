#!/bin/bash
export MIX_TARGET=ovcs_base_can_system_rpi4

mix deps.get
echo "Firmware"
mix firmware
