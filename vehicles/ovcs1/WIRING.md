# OVCS1 Wiring Reference

Pin-level notes for the donor harnesses and custom looms on the OVCS1
(2007 VW Polo → Nissan Leaf AZE0 EV conversion). Kept terse on purpose —
one section per harness, one bullet per wire. Expand as new connections
are added; do not move this file out of the vehicle package.

For the physical topology (which bus runs at what bitrate, which Pi owns
which connector), see
[`docs/hardware_architecture.md`](../../docs/hardware_architecture.md).

## Leaf harness

### Inverter Ignition relay

* 42

### Ground

* EMC Shield
* Inverter 47 - 49
* 10
* 21

### 12V+

* Inverter 46 - 48
* 20
* 5


## IBooster

### Ignition relay

* Yellow

### Yaw CAN

* 4 wire plug; 1 (CAN High) - 2 (CAN Low)

### Vehicle CAN

* 4 wire plug; 3 (CAN High) - 4 (CAN Low)

## Steering pump

### CAN

* 2 wire plug: 1 (CAN High) - 2 (CAN Low)

## Polo

### Drive CAN

* 2 wire plug: 1 (CAN High) - 2 (CAN Low)