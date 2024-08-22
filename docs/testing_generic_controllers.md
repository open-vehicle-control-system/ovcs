# Testing Generic Controllers

The `VmsCore.Controllers.TestController` module allows you to test all Output and inputs of the Arduino generic controllers.

## Adopting a generic controller as a `TestController` locally:

### Start the local CAN  and VCAN networks:

```sh
$ ./scripts/setup_can.sh
$ ./scripts/setup_virtual_can.sh
```

### Start the VMS locally (with OVCS on CAN0 and the other networks on VCAN):

```sh
$ cd vms/api
$ CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 iex -S mix phx.server
```

### Emit the adoption frame (CAN also be run on the VMS host itself)

```sh
iex(1)> VmsCore.Controllers.Configuration.start_adoption("test_controller")
:ok
```

### Adopt the configuration on the controller

Press the adoption button on the controller itself
(If USB is connected the adopted configuration is show on the Serial output)

### Control the Digital I/Os:

* Enable ALL digital pins (Main board + 2 expansion boards):

```sh
iex(1)> VmsCore.Controllers.TestController.on()
:ok
```

* Disable ALL digital pins (Main board + 2 expansion boards):

```sh
iex(1)> VmsCore.Controllers.TestController.off()
:ok
```

* Enable/Disable a specific digital pin:

```sh
iex(1)> VmsCore.Controllers.TestController.on(5)
:ok
iex(1)> VmsCore.Controllers.TestController.off(5)
:ok
```