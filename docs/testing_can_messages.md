# Testing with can messages

OVCS relies on CAN messages. These can be quite different depending on the vehicule the components you are using come from.

Our initial vehicule, OVCS1, is a Volkswagen Polo Bluemotion from 2007.

The following commands allow you to test the applications locally, when configured as the original OVCS1 Polo.

Use these commands in a terminal on your host to see the status change on the debug page of the Infotainment system.

## Handbrake 

* engaged: `cansend vcan0 320#03027F0100000000`
* disengaged `cansend vcan0 320#03007F0100000000`

## RPM

* 1250 rpm: `cansend vcan0 280#0000881300000000`
* 2250 rpm: `cansend vcan0 280#0000282300000000`

## Using candumps

You can simulate the vehicle (infinite loop) with the following command to see data flowing to the frontend application: `canplayer -l i -I candumps/candump-standard-test.log vcan0=can0 vcan1=can1`

This uses a dump of all messages received on the CAN bus for a defined period of time from the original OVCS1 Polo.

Next: [Hardware architecture](./hardware_architecture.md)