# Range fans

A Foxglove message converter: `sensor_msgs/Range` topics become drawable
in the 3D panel, which does not draw `Range` itself. Each reading is the
outline of a fan the width of the sensor's beam, cut at the distance,
in the sensor's frame: red near, green far, grey out to the maximum
range when nothing is in range (+Inf), red at the minimum when something
is closer (-Inf). A fan disappears half a second after its last reading.

Build and install it into the Foxglove desktop app on this machine:

```bash
npm ci
npm run local-install
```

or build `npm run package` and drag the `.foxe` file into Foxglove.
Then tick the `Range` topics in a 3D panel's topic list.
