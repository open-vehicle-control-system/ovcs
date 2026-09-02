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
and it exercises wheelbase, track and kingpin width together. A model
that drives convincingly can still report distance that is wrong by a
constant factor, which is exactly the state the previous model was in.

Two traps in *measuring* this, both of which caught the first version
of `drive_test.py`:

- **Arc, not chord.** The straight-line displacement between start and
  end pose is not the distance travelled once the path curves. Over a
  199-degree turn the chord is 0.57x the arc — which reads exactly
  like the vehicle driving at half the commanded speed.
- **Unwrapped yaw.** A quaternion converts to a heading in
  `[-pi, pi]`, so subtracting first from last silently loses a whole
  turn, or flips its sign.

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

## Not here yet

Milestone 1 is a driveable, correctly-proportioned vehicle. No sensors
— no stereo pair, no IMU. The next step is publishing the same topic
contract the real vehicle does (`/stereo/left/image_raw/compressed`,
`/stereo/*/camera_info` at 480x270, `/imu`), so the Foxglove layout
and the Hailo detector work against the sim unchanged.

The simulator is also the natural place to settle the
`base_link -> stereo_left` transform that is still a placeholder on the
real vehicle: in simulation the camera's true position is known
exactly.
