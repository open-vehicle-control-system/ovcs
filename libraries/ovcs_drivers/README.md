# ovcs_drivers

Elixir drivers for the physical chips OVCS hardware uses (IMUs, PWM
generators, ADCs, …). Each driver lives in its own top-level module
namespace (`BNO085`, future `PCA9685`, …) and exposes its sample /
output struct in pure hardware vocabulary — no ROS, no Cantastic,
no OvcsBus types — so that:

- Consumers (bridges, controllers) wire drivers into their own
  framework via an adapter, without bending the driver.
- Any individual driver can be lifted into its own standalone
  library later without renaming.

## Driver kinds

The library defines a *behaviour* per kind of driver (`OvcsDrivers.Imu`,
eventually `OvcsDrivers.PwmGenerator`, `OvcsDrivers.Adc`, …) so
implementations are swappable from the supervision tree without any
consumer-side change. Each kind also owns a sample / output struct
shared across all drivers of that kind — `OvcsDrivers.Imu.Sample`
carries `kind, x, y, z, w` for every IMU regardless of chip.

Current kinds:

| Kind                  | Behaviour                | Sample / output struct          | Drivers          |
|-----------------------|--------------------------|---------------------------------|------------------|
| IMU                   | `OvcsDrivers.Imu`        | `OvcsDrivers.Imu.Sample`        | `BNO085.I2C`, `BNO085.Dummy` |

New kinds land alongside their first concrete driver — defining a
behaviour with zero implementations is dead code; wait until you have
a chip driver to anchor the contract.

## Layout

```
lib/
  imu.ex                          # OvcsDrivers.Imu behaviour
  imu/sample.ex                   # %OvcsDrivers.Imu.Sample{kind, x, y, z, w}
  bno085/                         # one driver, implements OvcsDrivers.Imu
    i2c.ex
    dummy.ex
  <next_chip>/...
```

## Adding a driver

1. New directory `lib/<chip>/`.
2. Driver GenServer in `lib/<chip>/<bus>.ex` (`i2c.ex` / `spi.ex` /
   `gpio.ex`). Use `Circuits.<Bus>` directly. Declare `@behaviour
   OvcsDrivers.<Kind>` and implement its callbacks.
3. Emit the kind's sample struct via `GenServer.cast(listener,
   {:<kind>_sample, %OvcsDrivers.<Kind>.Sample{}})` for sensor-style
   kinds, or accept setter calls for output-style kinds (PWM, etc.).
4. Adapters in the consuming application translate the generic
   sample struct into framework messages (e.g.
   `RosBridge.Imu.Adapter` for the ROS bridge).

## Adding a new kind

1. Define `OvcsDrivers.<Kind>` behaviour in `lib/<kind>.ex`.
2. Define `OvcsDrivers.<Kind>.Sample` (or `Output`, etc.) in
   `lib/<kind>/sample.ex`.
3. Land a first driver implementing it in the same PR — no
   behaviour-only stubs.
