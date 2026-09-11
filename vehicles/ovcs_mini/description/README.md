# OVCS Mini visual model

The body shell is hidden by default (`show_body:=false` in Xacro).
The chassis, wheels, bumpers and suspension visuals remain visible.
Use `show_body:=true` when expanding the model to include the experimental shell.

An original procedural approximation of the **Pro-Line VW Baja Bug 3238-62**
body on a **Traxxas Slash 4x4 Ultimate** chassis: curved cabin, glazing,
bonnet, cut-down fenders, round headlights, bumpers, treaded tyres and spoked rims. It is not manufacturer CAD and
does not reproduce the paint scheme or the OVCS electronics installation.

The visual meshes do not define collision, inertia, suspension or steering.
The existing rigid suspension and Ackermann simulation remain approximations.
Mesh proportions are estimates; the meshes scale with the URDF shell envelope,
wheel radius and tyre width. Fender spacing approximates the shell's 318 mm nominal wheelbase; the chassis
keeps its 324 mm axle spacing. Suspension arms and shocks are static visuals.

## Component colours

Colours identify functions rather than the vehicle's actual finishes:
blue chassis; orange suspension arms and towers; yellow shocks; purple steering
knuckles; green cameras on a teal mount; slate bumpers;
black tyres and silver rims. The IMU has no visual geometry.

## Local RViz preview

With ROS Lyrical, `xacro`, `robot_state_publisher`, `joint_state_publisher_gui`
and `rviz2` installed, run from the repository root:

```bash
source /opt/ros/lyrical/setup.bash
ros2 launch vehicles/ovcs_mini/description/view.launch.py
```

The launcher resolves shared macros and meshes directly from the checkout.
For RViz's per-link material handling, the preview places additional visuals in
massless fixed child links. This preserves their poses and individual colours;
the simulation description and its dynamics are unaffected.
Its Qt settings apply only to the preview processes to avoid Wayland/HiDPI
viewport flickering. The grid spacing is 100 mm. Joint sliders are independent;
Gazebo's Ackermann controller is not running in this preview.

The Gazebo server and GUI both need the description directory mounted at
`/opt/ovcs/vehicles/ovcs_mini`, as configured in `compose/local/simulation.yml`.
The GUI loads its own copies of the meshes.

## Dimensional audit

Reference vehicle: Traxxas **68277-4**, not a 1/16 Slash or a Slash 2WD.
Reference documents: [product page](https://traxxas.com/slash-4x4-vxl-ultimate-68277-4)
and [owner's manual](https://traxxas.com/media/productattach/C-68277-4/2/68277-4-om-en-r00.pdf).
The identified shell is [Pro-Line 3238-62](https://wheelspinmodels.co.uk/i/proline-volkswagen-vw-beetle-body-fits-29756/).
The listing specifies 489 × approximately 191 × 152 mm; its width entry
"1.91mm" is a typo (7.5 inches = 190.5 mm, and the Q&A confirms 191 mm).
19.3 inches and 489 mm also differ slightly through catalogue rounding; the
model uses the stated metric dimensions.

These links identify the vehicle; they do not certify measurements of the OVCS build.

| Quantity | Current model | Validation status |
| --- | --- | --- |
| Axle spacing | 324 mm | Nominal catalogue value; not measured on this vehicle |
| Overall visual length including bumpers | 568 mm | Model envelope; not the bare body-shell length |
| Baja shell length | 489 mm | Product listing for 3238-62 |
| Baja shell width | 191 mm | Rounded from 7.5 inches; not tyre-to-tyre width |
| Baja shell height | 152 mm | Shell only, before mounting |
| Shell mounting offset | 45 mm | Estimate, giving a model roof height of 197 mm |
| Shell nominal wheelbase | 318 mm | Body fitment; does not change chassis axle spacing |
| Tyre diameter | 109.6 mm | Rounded from nominal 109.5 mm; measure loaded rolling radius for odometry |
| Tyre width | 45 mm | Estimate |
| Wheel-centre track | 296 mm | **Unverified**; catalogue "track" must not be assumed to mean centre spacing |
| Outside tyre width | 341 mm | Calculated as 296 + 45; inconsistent with a 296 mm overall-width interpretation |
| Steering-axis spacing | 296 mm | Matches the URDF wheel-centre pivots; zero scrub radius approximation |
| Chassis clearance | 30 mm | Estimate; depends on suspension setup and load |
| Total mass | 2.41 kg | Unverified for this battery/electronics configuration |

Do not claim full dimensional validation from matching two declarations in code.
Before changing the dynamics, measure outside tyre width, tyre width, axle spacing,
steering-pivot spacing, ride height, shell mounting height and ready-to-run mass including OVCS equipment.
At zero toe/camber, centre track is outside tyre width minus one tyre width.
`OvcsMini.geometry/0` and the geometry tests must agree with any accepted change.

## Geometry and dynamics checks

The chassis is a flat tray with a wider centre and narrow ends, without raised rails. Visual and
collision boxes, including the simple bumper bars, share dimensions; the axle regions leave clearance for the
front tyres through their full steering sweep. Chassis inertia is still a
lumped rectangular approximation, not a CAD-derived tensor.

The declared 2.41 kg includes both cameras and the IMU as well as wheels and
steering links. It is a consistent model mass budget, not a measured vehicle mass.

`steering_limit` is the virtual bicycle angle (0.52 rad). Individual wheel
joint limits are derived from the minimum radius and actual pivot spacing,
so the inner wheel can reach the tighter angle. Gazebo 10 velocity mode uses
`L / sin(parameter)` for its minimum radius; its parameter is therefore
`asin(tan(steering_limit))` to agree with the vehicle's `L / tan(steering_limit)`.
See [Gazebo's controller source](https://github.com/gazebosim/gz-sim/blob/gz-sim10/src/systems/ackermann_steering/AckermannSteering.cc).

The upstream controller remains approximate: it commands equal front/rear
wheel rates on each side and estimates odometry using the mean front steering
angle. Tight-turn odometry is therefore not independent ground truth.
The model has no compliant suspension, chassis flex, measured tyre slip or
modelled differential internals. The visible rods and shock bodies are fixed
hardware illustrations: one straight arm, one slender support and one shock per
wheel. Their attachment points coincide with the tray, supports and arms;
they do not introduce suspension travel.

Run structural checks in a sourced ROS environment:

```bash
python3 vehicles/ovcs_mini/description/test_model.py
```

These check mass accounting, inertia validity, pivot/controller consistency,
steering targets at both stops, tyre/chassis clearance, matching structural visuals
and collisions, mesh paths, and stereo optical-frame orientation.

## Editing visuals

`generate_meshes.py` uses the Python standard library and writes the bundled STL
assets deterministically. Body meshes use a unit envelope; wheel meshes use unit
radius and unit width with the axle along z. Materials are in `visuals.xacro`.

```bash
python3 vehicles/ovcs_mini/description/generate_meshes.py
```

Keep the STL assets with the model so viewers do not need Python or a mesh editor
to load them. These are visual surfaces, not watertight manufacturing meshes.
