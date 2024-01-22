#!/bin/sh
export MIX_TARGET=ovcs_ecu_system_rpi4
cd ./ovcs_ecu_firmware
mix deps.get
mix firmware