# vision dashboard

React app (Vite, Zustand, Tailwind over `@ovcs/ui`) for the vision unit. It talks to [`vision_api`](../api) over HTTP (JSON:API) and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

The page is laid out for a laptop screen:

- the header: the title with the firmware's commit and Nerves system, read again whenever the unit comes back, the parameters' error when there is one, the unit's status inline (the ROS 2 exporter's link on a unit that has one, Hailo, CPU and stereo load, and Calibration reading uncalibrated on a unit without one), and the dark mode switch, whose choice the browser keeps;
- a menu on the left, in three sections: Main (Overview, Calibration), Pipelines (the stereo and detection pipelines, each a numbered flow of its steps, detection as one greyed line on a unit without a detector) and Exporters (the unit's exporters, each with its status, listed again whenever the unit comes back, a failed listing tried again until one succeeds, and the API);
- the Overview: the previews at the full width, the left and right cameras with their synchronisation, row alignment and sharpness between them, then the depth with its colour scale;
- a step's page: one line on what it does, with How it works opening a paragraph on why it matters, what its settings change and what to watch, then its parameters with the save bar (Save, Discard, Reset all), beside the same previews, which keep playing when you go between it and the Overview;
- the Calibration page: the calibration in use (its source, each camera's intrinsics and distortion, the baseline, Download, and Return to built-in when a stored one is in use), then a new calibration: the board in inner corners, remembered in the browser, both previews with the corners found drawn over them and the four coverage bars, then the result's reprojection errors beside the calibration in use, with Apply, Download and Discard. Joining its `calibration` channel turns the unit's board detection on, so only this page joins it, while open;
- an exporter's page: the ROS 2 page (the node, its topics with their rates, its services), the API page (the resources and channels), and for another exporter its status, the outputs it reads and a button per action it declares, which runs the action and downloads the file it answers, or shows its result or its error.

A step's page is kept in the URL as `?box=<group id>` (`?box=stereo.disparity`), an exporter's as `?exporter=<id>` (`?exporter=ros2`; `?page=ros2` and `?page=api` open those exporters' pages too), any other page but the Overview as `?page=<page>` (`?page=calibration`). The parameters are polled every second, so values set by an automatic mode stay current.

`src/stores/calibration.js` holds the calibration session and the calibration in use, from the `calibration` channel. `src/stores/parameters.js` holds the groups and parameters; the controls and the save bar are `OvcsParameterControl` and `OvcsSaveBar` from `@ovcs/ui/react`.

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision/README.md).
