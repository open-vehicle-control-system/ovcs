# SimulatorRunner

Runs a vehicle's simulated hardware on its own BEAM, with no ROS: the simulated components of [SimulatorCore](../core/README.md), on virtual CAN, moving `SimulatorCore.Vehicle`'s own motion model. Start it before the VMS, so the VMS boots against hardware that already answers, as on the vehicle.

The vehicle declares its simulated hardware in `simulator/0`, typed `OvcsVehicle.simulator/0`: the motion model's parameters, the simulated components, the CAN topology of the frames they read and emit, and the host CAN mapping. The OVCS Mini reference vehicle's is in `vehicles/ovcs_mini/lib/ovcs_mini.ex`, with its topology in `vehicles/ovcs_mini/priv/can/simulator.yml`.

## Run it

Create the vehicle's vcan interfaces (`./ovcs can setup <vehicle>`), compile the vehicle (`mix compile` in `vehicles/<vehicle>/`), then:

```sh
VEHICLE=OvcsMini mix run --no-halt
```

`CAN_NETWORK_MAPPINGS` overrides the vehicle's host mapping, as for the other firmwares.

Once the simulated components run and emit their frames, the runner prints exactly this line on standard output:

```
OVCS simulator ready
```

Start the VMS after it.

## Testing

```sh
mix test --no-start
```
