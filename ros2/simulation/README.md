# simulation — the OVCS Mini in Gazebo

A Gazebo **Jetty** model of the OVCS Mini (a Traxxas Slash 4x4, 1/10
scale short-course truck), plus the stack to run it. Third sibling to
`ros2/vehicule` (on the car, balenaOS) and `ros2/base` (the operator's
box); this one only ever runs on a workstation.

It speaks Zenoh like everything else, so a simulated vehicle appears
on the same fabric as a real one and existing tooling — `ros2 topic`,
Foxglove — needs no special case.

```
ros2/simulation/          the simulator — baked into the image
  common/                 macros shared by every model
  worlds/                 SDF worlds
  launch/                 sim.launch.py — the whole stack
  config/                 gamepad mapping
  scripts/                drive_test.py — verifies geometry, not motion

vehicles/ovcs_mini/
  description/            the Mini's model — mounted, not baked
```

**A model describes one vehicle, so it lives with that vehicle.** It
sits beside `priv/` rather than inside it: `priv` is an Elixir
application's private directory and nothing in the Elixir tree reads a
xacro, but the model is still the Mini's, not the simulator's.

Adding a vehicle is a `description/` directory under it containing
`<name>.urdf.xacro`, one mount line in `docker-compose.yml`, and:

```sh
docker compose exec sim ros2 launch /opt/ovcs/launch/sim.launch.py vehicle:=<name>
```

## Running it

```sh
# A router, if you have no vehicle on the LAN.
docker compose -f ../base/docker-compose.yml --profile standalone up -d zenohd

docker compose up -d
docker compose logs -f sim
```

Drive it:

```sh
docker compose exec sim bash -lc \
  'ros2 topic pub -r 10 /cmd_vel geometry_msgs/msg/Twist \
     "{linear: {x: 1.0}, angular: {z: 0.3}}"'
```

Two things are **separate services**, so the simulation itself needs
neither a display nor a gamepad — `docker compose up` works on a bare
machine:

```sh
# gamepad
docker compose --profile teleop up -d teleop

# Gazebo GUI
xhost +local:docker
docker compose --profile gui up -d gz-gui
```

## Verifying it

```sh
docker compose exec sim python3 /opt/ovcs/scripts/drive_test.py
```

Expected, and what each number proves:

```
straight: 1.0 m/s        ->  1.000 m/s     wheel radius and odometry scale
turn 1.0 m/s, 0.5 rad/s  ->  R = 2.005 m   wheelbase and steering geometry
turn 2.0 m/s, 0.5 rad/s  ->  R = 3.984 m   the above, at a second point
```

The turning radius is the interesting one: it must equal `v / omega`,
and it exercises wheelbase, track and kingpin width together.

```sh
mise run verify-drivetrain            # up, drive, check, down
KEEP_UP=1 mise run verify-drivetrain  # leave the stack up to poke at
```

### /odom cannot catch a wrong wheel radius

The obvious check — drive at 1 m/s and see whether `/odom` agrees — is
worthless, and this was measured rather than reasoned about. Setting
`<wheel_radius>` to 0.1 against the model's real 0.0548 leaves `/odom`
reporting a flawless 1.000 m/s while the wheels turn at 10.0 rad/s, so
the car is really crawling at `10.0 x 0.0548 = 0.548` m/s.

The radius cancels inside `AckermannSteering`: the commanded speed is
divided by it to get a joint velocity, and the joint velocity is
multiplied by it again to get odometry. `/odom` is a command echo, and
the vehicle *reports* correctly while **driving** wrong — the opposite
of what `gazebo_ackermann.xacro` used to claim.

So the wheel radius is checked against `/joint_states`, which reports
the physical joint velocity. Ground speed is that velocity times the
real wheel radius, and it must match what odometry claims. In a good
run the wheels turn at 18.25 rad/s and `18.25 x 0.0548 = 1.000`.

Two traps in *measuring* this, both of which caught the first version
of `drive_test.py`:

- **Arc, not chord.** The straight-line displacement between start and
  end pose is not the distance travelled once the path curves. Over a
  199-degree turn the chord is 0.57x the arc — which reads exactly
  like the vehicle driving at half the commanded speed.
- **Unwrapped yaw.** A quaternion converts to a heading in
  `[-pi, pi]`, so subtracting first from last silently loses a whole
  turn, or flips its sign.

## Checking perception automatically

`verify_perception.sh` is the perception sibling of
`verify_drivetrain.sh`. Both assert and exit non-zero, so both run
unattended:

```sh
mise run verify-perception                    # stereo only
OVCS_DETECTOR=stub mise run verify-perception  # + the depth-fusion check
KEEP_UP=1 mise run verify-perception           # leave the stack up to poke at
```

It starts the router, the simulator and the real perception bridge,
measures for 20 s, checks, and tears everything down.

### The expected distances are derived, not recorded

They come from `worlds/workshop.sdf` and
`vehicles/ovcs_mini/description/`, so moving a box or the camera
updates the expectation rather than silently invalidating it:

```
box_1m     x=1.0, 0.3 deep  ->  front face 0.85 m from origin
box_2m     x=2.0, 0.4 deep  ->  1.80 m
back_wall  x=6.0, 0.2 deep  ->  5.90 m
camera_x = wheelbase/2 - 0.120 = 0.042 m
```

giving 0.808 m, 1.758 m and 5.858 m from the lens. A run measures:

```
  PASS  depth median: 0.810 m, world says 0.808 (tolerance 0.050)
  PASS  depth p75: 1.754 m, world says 1.758 (tolerance 0.100)
  PASS  depth p95 within the room: 5.847 m, back wall at 5.858
  PASS  fused detection depth: 0.809 m, world says 0.808 (tolerance 0.050)
```

### Geometry is checked tightly, throughput is not

Geometry is machine-independent: if the median depth is 0.808 m then
the disparity scale, the rectification and the intrinsics all agree
with the world. Throughput is not — it depends on the CPU and on
whether Gazebo is software-rendering — so rates are checked against a
floor low enough to mean "the pipeline is running", not a target that
would fail on a slower machine while saying nothing about correctness.

### What it catches

Halving `@disparity_fixed_point_scale` in `StereoCamera.OpenCV` — a
plausible edit, and invisible on screen because the depth image still
looks like a depth image — fails three checks and nothing else:

```
  FAIL  depth median: 0.405 m, world says 0.808
  FAIL  depth p75: 0.877 m, world says 1.758
  FAIL  fused detection depth: 0.404 m, world says 0.808
  PASS  disparity rate / encoding / coverage / point cloud
```

Rates and coverage still passing is the point: the checks discriminate
between "slow" and "wrong".

## Running the perception pipeline against it

The whole stereo stack — SGBM, rectification, publishers, detector —
runs unchanged against the simulator. Only the camera driver differs:
`RosBridge.Camera.Zenoh` subscribes to a ROS image topic and emits the
same frames a physical driver does.

```sh
./ovcs can setup ovcs_mini          # once — Cantastic needs vcan0 to exist

cd bridges/firmware
VEHICLE=OvcsMini OVCS_SIM=1 ZENOH_ENDPOINT_IP=127.0.0.1 \
  BRIDGE_FIRMWARE_ID=ros_perception CAN_NETWORK_MAPPINGS=ovcs:vcan0 \
  iex -S mix
```

`bridges/firmware`, not `bridges/ros_bridge`: the bridge library has no
`config/` of its own, so `CAN_NETWORK_MAPPINGS` is never read there and
Cantastic dies with "CAN network mappings are missing from the Cantastic
configuratiion". The firmware project is what `./ovcs run` starts, and
its `config/runtime.exs` is where that variable is consumed.

`BRIDGE_FIRMWARE_ID` is required too. Without it `firmware_id/0` falls
back to `"ros"`, which selects `ros_bridge_config(:host, "ros")` — the
joy/IMU wiring — and the stereo pipeline never starts at all, with no
error to say why.

`OVCS_SIM` selects the simulated wiring, so it cannot be picked up by
accident on the vehicle. No `:hailo_detector` there — a workstation
has no accelerator.

Measured against `workshop.sdf`: 30.3 Hz, 61.2% depth coverage, and a
depth histogram that lands where the world says it should:

```
median 0.81 m   the 1.0 m box, front face 0.808 m from the lens
p75    1.75 m   the 2.0 m box, front face 1.758 m
```

That agreement to a centimetre is the real test — it checks the
geometry, not just that pixels arrived.

### Two things that produce no disparity at all

**An untextured world.** SGBM correlates local patches; a flat ground
plane under a blank sky gives it nothing to correlate, and disparity
comes back empty. `empty.sdf` is for driving tests only — use
`workshop.sdf` for anything involving depth.

**The wrong calibration.** The vehicle's own calibration is *actively
wrong* here, and quietly so. Gazebo renders an ideal pinhole: no lens
distortion, eyes already coplanar. Feeding it distortion coefficients
and rectification rotations that describe a physical lens warps the
two views apart rather than into alignment. Coverage sat at **5.4%**
until the simulator got its own calibration
(`vehicles/ovcs_mini/priv/calibration/sim/`), where D is zero and R is
identity. The same scene then measured **61.2%**.

The focal length in that file is still the real one, scaled to the
capture resolution — so the simulated *optics* match the vehicle while
the *distortion model* matches the simulator.

## Where the model came from

It replaces [open-vehicle-control-system/traxxas][traxxas], which
could not be ported for two independent reasons.

**Gazebo Classic.** That model used
`libgazebo_ros_ackermann_drive.so`, a Classic plugin. Classic is
end-of-life and the plugin exists in no modern Gazebo. The replacement
is Gazebo's own `AckermannSteering` system, reached through
`ros_gz_bridge` instead of by linking ROS into the plugin.

**The geometry was not a Slash 4x4.** Comparing that model to the
published specification:

| | old model | real Slash 4x4 |
|---|---|---|
| Wheel radius | 0.100 m | **0.0548 m** (109.5 mm tyre) |
| Track | 0.400 m | **0.296 m** |
| Wheelbase | 0.350 m | **0.324 m** |
| Chassis mass | 0.5 kg | **2.41 kg** vehicle |

The wheels were nearly double the real diameter and the track 35% too
wide. Ackermann odometry is computed from wheel radius and track, so
both errors propagated into every distance and turn rate the simulator
reported. Two outright bugs came with them: the rear wheels were
mirrored relative to the front, and one rear collision cylinder was
twice its visual length.

`inertial_macros.xacro` and the gamepad mapping in `config/` are
reused from that repo unchanged — they were engine-agnostic and
already correct.

[traxxas]: https://github.com/open-vehicle-control-system/traxxas

## Measured vs estimated

`vehicles/ovcs_mini/description/ovcs_mini.urdf.xacro` declares every dimension once and
marks which are which. Measured values come from the Traxxas
specification; **ESTIMATE** marks what the specification does not
publish — tyre width, chassis-tub dimensions, ground clearance,
steering lock, and the mass split between chassis and wheels. Those
are the numbers to revisit first if the vehicle behaves oddly.

The chassis carries its mass in a low tub rather than in the full
193 mm envelope, because a centre of gravity at half the body height
rolls the truck over in its first corner.

## Why Jetty, and why the stack is on Lyrical

Gazebo pairs with ROS, and the table is strict: ROS 2 Jazzy supports
**only** Harmonic, and Jetty against Jazzy is unsupported outright.
Getting Jetty (the current LTS) meant moving the stack from Jazzy to
**Lyrical**.

That turned out to be cheap, and it was checked rather than assumed:

- All **14 hardcoded `RIHS01_` type hashes** in `ros_bridge` are
  **identical** between Jazzy and Lyrical, so no message encoder
  changed and the golden fixtures stayed valid.
- **zenoh is 1.9.0 on both sides** — the same version `zenohex 0.9.0`
  pins — despite `rmw_zenoh` jumping 0.2.9 to 0.10.5.
- A Lyrical container was pointed at the running vehicle's router and
  decoded every topic the Jazzy-era Elixir bridge publishes.

The Elixir and Nerves side is distro-agnostic in the first place: it
speaks the rmw_zenoh wire protocol directly and links nothing from
ROS.

### Known details

The odometry frame comes out as `ovcs_mini/odom` while its child is
plain `base_link` — `AckermannSteering` namespaces the parent by model
name and there is no verified tag to override it (`<child_frame_id>`
exists, `<frame_id>` does not). Harmless with one vehicle; something
to remap at the bridge if a consumer expects a bare `odom`.

### Known wrinkle

`ros2 topic echo` and friends fail under Lyrical with
`ResponseError: unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'`
— a `ros2cli` daemon bug on Python 3.14. Pass `--no-daemon`:

```sh
ros2 topic echo --no-daemon /odom
```

## Navigating with Nav2

```sh
mise run verify-nav2            # up, navigate, check, down
KEEP_UP=1 mise run verify-nav2  # leave the stack up to poke at

# or by hand
docker compose --profile nav2 up -d nav2
docker logs -f ovcs-nav2
```

Nav2 1.5.1 in its own image (`nav2/Dockerfile`), behind a compose
profile so a plain `up -d` stays a bare simulator. No map and no AMCL:
every frame is `odom` and both costmaps roll. That is enough to prove
the velocity path drives an Ackermann vehicle without taking on the
map/SLAM question, and it avoids a fake static `map -> odom`, which is
the usual shortcut and worse, because it looks like localisation.

### Four things that each fail silently

Every one of these cost a debugging cycle, so they are worth knowing
before changing the configuration.

- **Nav2 publishes `TwistStamped`.** `nav2_util::TwistPublisher`
  defaults `enable_stamped_cmd_vel` to *true* — the doc comment in that
  header still claims otherwise, and the code wins. The existing
  `/cmd_vel` bridge is unstamped, so Nav2 gets its own topic
  (`/cmd_vel_nav`) and its own bridge node feeding the same Gazebo
  topic. Without that, a healthy-looking Nav2 moves nothing at all.
- **`motion_model` names a plugin *instance*, not a class.** The class
  comes from `<instance>.plugin`. Naming the class directly fails with
  "No 'plugin' param for param ns!". Leaving `motion_model` unset is
  fatal rather than silent, which is the good outcome: MPPI defaults it
  to the instance name `diff_drive`, which has no `.plugin` param
  either, so the controller refuses to configure.
- **The odometry frame was `ovcs_mini/odom`.** The Ackermann plugin
  derives it from the model name unless `<frame_id>` says otherwise, and
  Nav2 rejects it: every costmap logs `Invalid frame ID "odom" ... frame
  does not exist` and never activates.
- **`Spin` aborts navigation on a car.** Both stock behaviour trees put
  it in their recovery branch; an Ackermann vehicle produces no motion
  at all from a spin command, so it runs its full duration and burns a
  recovery slot. Both trees are overridden to drop it. The `spin`
  *server* stays loaded, because bt_navigator resolves action servers
  for both trees at activation and will not come up without it.

### Reaching the goal proves almost nothing

Gazebo's `AckermannSteering` quietly ignores commands it cannot
execute, so a controller configured for a differential-drive robot
still arrives — it just commands arcs the real steering could never
cut. Measured: with `mppi::DiffDriveMotionModel` substituted in, the
vehicle reached the tight goal *better* than the correct configuration
did (0.30 m versus 0.53 m) while commanding a yaw rate 3.68x the
kinematic limit.

So `nav2_test.py` checks what was **commanded**, and uses two goals
because no single goal can test both things:

| goal | required arc | asserts |
|---|---|---|
| 3.0 m ahead, 1.0 m across | 5.00 m | arrival |
| 0.8 m ahead, 1.4 m across | 0.93 m | the kinematic limits |

An easy goal never approaches the radius limit — an unconstrained
controller drives it at 0.74x, under the threshold, so the check
passes. A tight goal does bite, but the *correct* configuration then
needs to shuffle and may not arrive at all, so arrival is reported
rather than asserted there. Each goal is asked only what it can
answer.

### Known limitations

- There is no `nav2_smac_planner` in the Lyrical archive, so global
  plans come from NavFn and are **not kinematically feasible** — they
  can contain corners this car cannot drive, and MPPI has to carry
  that. Fine in an open workshop; a real constraint in tight spaces.
- `yaw_goal_tolerance` is deliberately ~pi. A car cannot rotate to a
  commanded final heading, so requiring one leaves it stuck at the goal
  until the action times out.
- Nothing arbitrates between `/cmd_vel` and `/cmd_vel_nav`. Run teleop
  or Nav2, not both — which mirrors OVCS Mini, where nothing arbitrates
  between the radio and ROS either.

## Not here yet

No IMU, so `/imu` is absent and anything downstream of it is untested
here.

The camera bar's **height** is still the one unmeasured number on the
vehicle (`camera_z`, 0.12 m, guessed). Forward offset and baseline are
measured; height is not, in either the model or the real
`stereo_transforms`.
