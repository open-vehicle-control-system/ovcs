#!/bin/sh
export MIX_TARGET=ovcs/ovcs_ecu_system_rpi4
cd ./ovcs_ecu_firmware
mix upload nerves.local
