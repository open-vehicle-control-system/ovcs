# vision dashboard

React app (Vite, Zustand, Tailwind over `@ovcs/ui`) for the vision unit. It talks to [`vision_api`](../api) over HTTP (JSON:API) and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

The page is laid out for a laptop screen:

- the header: the title with the firmware's commit and Nerves system, read again whenever the unit comes back, the parameters' error when there is one, the unit's status inline (Zenoh, Hailo, CPU and stereo load), and the dark mode switch, whose choice the browser keeps;
- a menu on the left, in three sections: Main (Overview, Calibration), Pipelines (the stereo and detection pipelines, each a numbered flow of its steps, detection as one greyed line on a unit without a detector) and Exporters (ROS 2, API);
- the Overview: the previews at the full width, the left and right cameras with their synchronisation, row alignment and sharpness between them, then the depth with its colour scale;
- a step's page: one line on what it does, with How it works opening a paragraph on why it matters, what its settings change and what to watch, then its parameters with the save bar (Save, Discard, Reset all), beside the same previews, which keep playing when you go between it and the Overview;
- the Calibration page, whose tools are still to come, the ROS 2 page (the node, its topics with their rates, its services) and the API page (the resources and channels).

A step's page is kept in the URL as `?box=<group id>` (`?box=stereo.disparity`), any other page but the Overview as `?page=<page>` (`?page=ros2`). The parameters are polled every second, so values set by an automatic mode stay current.

`src/stores/parameters.js` holds the groups and parameters; the controls and the save bar are `OvcsParameterControl` and `OvcsSaveBar` from `@ovcs/ui/react`.

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision/overview.md).
