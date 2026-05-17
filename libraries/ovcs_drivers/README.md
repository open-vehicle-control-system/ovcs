# ovcs_drivers

Elixir drivers for the physical chips OVCS hardware uses (IMUs,
PWM generators, ADCs, …). Each driver lives in its own top-level
module namespace (`BNO085`, `PCA9685`, …) and exposes its sample /
output struct in pure hardware vocabulary — no ROS, no Cantastic,
no OvcsBus types — so that:

- A consumer (a bridge, a controller) can wire the driver into its
  own framework without having to know which library to bend.
- Any individual driver can be lifted into its own standalone
  library later without renaming.

## Layout

```
lib/
  bno085/                       # Bosch BNO085 SH-2 IMU over I²C
    i2c.ex
    sample.ex                   # %BNO085.Sample{kind, x, y, z, w}
  <next_chip>/...
```

## Adding a driver

1. New directory `lib/<chip>/`.
2. Driver GenServer in `lib/<chip>/<bus>.ex` (`i2c.ex` / `spi.ex` /
   `gpio.ex`). Use `Circuits.<Bus>` directly.
3. Sample / output struct in `lib/<chip>/sample.ex` (or
   `reading.ex`, `output.ex`, etc. — match the chip's vocabulary).
4. Listener pattern: drivers `cast` `{:<chip>_sample, %Struct{}}` to
   pids registered via `register_listener/1`. Consuming application
   code is responsible for translating into its framework messages
   (e.g. `RosBridge.Imu.BnoAdapter` for the ROS bridge).

## Why no application-framework imports?

Hardware drivers should be independently testable, swappable, and
ultimately extractable into separate libraries (the BNO085 driver
may well become its own hex package someday). Keeping them
framework-agnostic protects that path.
