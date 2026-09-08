# TODO — before the first planner drive (PR #55)

Hardware steps in dependency order: deploy first, since the pulse
counter and the channel layout only exist on the new firmware.

## 0. Deploy

- [ ] Flash the main controller (Arduino R4 Minima) with the new
      generic-controller firmware via PlatformIO — it carries the
      `PulseCounter` code and the `pulse_pin0` bit in the adoption
      frame.
- [ ] Upload the VMS: `./ovcs upload ovcs_mini vms`.
- [ ] Re-adopt the controller, once. Its EEPROM predates `pulse_pin0`
      (bit 53 was filler), so the pin reads disabled until re-adopted:
      1. Start adoption from the dashboard's controller page, or in IEx:
         `VmsCore.Components.OVCS.GenericController.start_adoption(OvcsMini.Vms.MainController)`
      2. Press the adoption button (D2) on the Arduino within ~1 s —
         the configuration frame is only broadcast that long.
      3. Stop adoption.
- [ ] After any VMS redeploy: the controller sits in
      `VMS_MISSING_ERROR` until the dashboard's **Reset status** action
      is used. Every redeploy, not just this one.
- [ ] Sanity check: Speed and Wheel RPM on the dashboard are nil until
      the first pulse frame, zero once `0x709` streams. Spin the spur
      gear by hand: frequency rises, decays to zero two seconds after
      the gear stops.

## 1. Calibrate the speed ratio

The composer estimates `@pulses_per_revolution 1` × `@gear_ratio 2.72`
(Slash 4x4 transmission). Measure the real product; it is the divisor
both speed and wheel rpm use.

- [ ] Bench, wheels free. Watch the raw pulse count:
      `candump can0 | grep 709` — the count is the first 16-bit
      little-endian word.
- [ ] Mark a wheel. Turn the **spur gear** by hand until the wheel
      completes exactly one revolution; the counts elapsed are the
      product. Turn 5–10 wheel revolutions and divide to average out
      the ±1 edge.
- [ ] Write the measured number into
      `vehicles/ovcs_mini/lib/ovcs_mini/vms/composer.ex` (only the
      product of the two constants matters) and drop the ESTIMATE
      comments.

## 2. Verify the steering sign  ← DONE: measured right for a left command, so `steering_sign: -1`

Wrong sign + the yaw-rate clamp = a Nav2 left turn is full lock right.

- [ ] Wheels off the ground, level on `:manual` so nothing propels.
- [ ] Command a **tiny linear, large angular** so the steering goes to
      full lock while the throttle stays negligible. The steering angle
      is `atan(wheelbase·omega/v)` with `omega` clamped to
      `v/min_turning_radius`; a large `omega` is clamped and the angle
      collapses to `atan(wheelbase/min_turning_radius) = steering_limit`
      regardless of `v`. So `linear 0.05` gives full lock with a
      throttle of only `0.05 / max_speed` ~ 1%, below the ESC deadband —
      the wheels do not spin. (A zero `linear` clamps `omega` to zero
      and holds the wheels straight, so it cannot be zero.) The command
      must reach `RosVelocityCommand`; two ways:
      - **Through ROS** (needs the vehicle's Zenoh router up): publish
        to `/cmd_vel_nav`, the topic the Mini's bridge subscribes to
        (not `/cmd_vel`):
        `ros2 topic pub -r 10 /cmd_vel_nav geometry_msgs/msg/TwistStamped '{twist: {linear: {x: 0.05}, angular: {z: 2.0}}}'`
      - **Straight on CAN** (no ROS): inject `0x2B1` with an advancing
        sequence so `RosCommand.Freshness` keeps it live —
        `linear 0.05` → `0500`, `angular 2.0` → `D007`:
        `seq=0; while true; do printf -v s '%02X' $seq; cansend can0 "2B1#0500D007$s"; seq=$(((seq+1)%256)); sleep 0.05; done`
- [ ] Level to `:ros` (channel 6), commander to `:autonomous`
      (channel 5); both arm at the bench's zero speed (which needs
      `0x709` live, i.e. the controller re-adopted). Watch the servo.
- [ ] Steers **left** → `steering_sign: 1` is correct.
      Steers **right** → set `steering_sign: -1` in the Mini composer
      and delete the UNVERIFIED comment next to it.
- [ ] The throttle also commands ~1 m/s during this; wheels off the
      ground makes it a non-event. `linear: 0.5, angular: 2.0` spins
      less and answers the same question.

## 3. Verify the channel endpoints (lowest urgency)

Decoders assume 1000/1500/2000 ± 100
(`requested_control_level.ex` `@channel_margin`). The level's three
positions were already verified on the Mini; realistically this is
channel 5's two positions.

- [ ] `candump can0 | grep -E '2A0|2A1'` — channels are little-endian
      `uint16`, two bytes each: 1–4 on `0x2A0`, 5–8 on `0x2A1`.
- [ ] Move each switch through its positions: channel 6 (level, three
      positions), channel 5 (commander, two).
- [ ] Every position lands within ±100 of nominal → nothing to do.
      Outside → fix the endpoints in the transmitter, or widen
      `@channel_margin`. Failure mode is benign either way: an
      unmatched value falls back to `:manual` / `:teleop`.

## Afterwards

- [ ] Commit the two measured constants (ratio, sign) as one small
      commit.
- [ ] Strike the three items from PR #55's "Before the first planner
      drive" list; the PR is then un-draftable on its own merits.
- [ ] Merge PR #66 (nil-source throttle zeroing, parked) before or with
      #55 so its "a level that commands nothing zeroes the actuators"
      claim holds for every drivetrain.
