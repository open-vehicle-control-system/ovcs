# Parameter sliders

A Foxglove panel that edits a ROS 2 node's parameters with sliders,
menus and toggles. It reads each parameter's description from the node
(`describe_parameters`): numbers get a slider over their declared
range, strings with a fixed set of values a menu, booleans a toggle,
and read-only parameters are shown greyed. A value the node refuses
shows the node's reason under its control.

The panel settings choose the node (default `/ovcs_bridge_perception`)
and the name prefix of the parameters to show (default `stereo.`).
Foxglove lists it as "Parameter sliders", marked `[local]` because it
is installed from this folder rather than its extension registry.

Build and install it into the Foxglove desktop app on this machine:

```bash
npm ci
npm run local-install
```

or build `npm run package` and drag the `.foxe` file into Foxglove.
The camera tuning layout (`../../ovcs_camera_tuning.json`) uses it.
