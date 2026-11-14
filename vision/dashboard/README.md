# vision dashboard

React app (Vite, Zustand, Tailwind over `@ovcs/ui`) for the vision unit. It talks to [`vision_api`](../api) over HTTP (JSON:API) and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

The page is laid out for a laptop screen:

- the header: the title with the firmware's commit and Nerves system, read again whenever the unit comes back, the parameters' error when there is one, the unit's status inline (the ROS 2 exporter's link on a unit that has one, the NPU with its kind and load, the stereo load, and Calibration reading uncalibrated on a unit without one), and the dark mode switch, whose choice the browser keeps;
- a menu on the left, in four sections: Main (Overview), Calibration (the stereo cameras and each camera of its own, each opening its calibration), Pipelines (the stereo pipeline, each detection pipeline and each segmentation pipeline, each a numbered flow of its steps, with its total time at the end of its name's row and each step's time at the end of its box's first line, from the `status` channel's `pipelines`: steps computed in one pass show no time of their own, and a bracket along their right edge gives their one time and where they run, and an Inference step shows the accelerator's own time under its own; detection as one greyed line on a unit with no pipeline but the stereo one) and Exporters (the unit's exporters, each with its status, listed again whenever the unit comes back, a failed listing tried again until one succeeds, and the API);
- the Overview: the previews at the full width, the left and right cameras with their synchronisation, row alignment and sharpness between them, then the depth with its colour scale and each camera of its own, with its detection pipelines' boxes and its segmentation pipelines' classes drawn over it, and under it why they have no distances when the stereo depth does not reach it (the `status` channel's `distances`);
- a step's page: one line on what it does, with How it works opening a paragraph on why it matters, what its settings change and what to watch, open or closed for each step as it was left while the page stays loaded, then its parameters with the save bar (Save, Discard, Reset all), beside the same previews, which keep playing when you go between it and the Overview;
- the Calibration page: the calibration in use (its source, each camera's intrinsics and distortion, the baseline, Download, and Return to built-in when a stored one is in use), the calibrations kept on the unit, each with where it was made, Use, Rename, Download and Delete, then a new calibration: the board in inner corners, remembered in the browser, both previews with the corners found drawn over them and the four coverage bars, then the result's reprojection errors beside the calibration in use, with Apply, Download and Discard. Joining its `calibration` channel turns the unit's board detection on, so only this page joins it, while open;
- an exporter's page: the ROS 2 page (the node, its topics with their rates, its services), the API page (the resources and channels), and for another exporter its status, the outputs it reads and a button per action it declares, which runs the action and downloads the file it answers, or shows its result or its error.

A step's page is kept in the URL as `?box=<group id>` (`?box=stereo.disparity`), an exporter's as `?exporter=<id>` (`?exporter=ros2`; `?page=ros2` and `?page=api` open those exporters' pages too), any other page but the Overview as `?page=<page>` (`?page=calibration`). The parameters are polled every second, so values set by an automatic mode stay current.

Nothing shown outlives the link to the unit:

- the status is dropped when its channel fails, as when the socket closes, and after 3 s without one (`src/stores/status.js`), so the figures, badges and gauges read from it go with it;
- a preview drops its frame when its channel fails and says why it shows none: no frame yet, a stream the unit refuses, a video the browser cannot decode;
- the socket's heartbeat is 5 s (`src/services/socket.js`), so a link gone without closing is noticed within 10 s;
- a request the unit does not answer is aborted, after 5 s for a read and 15 s for an action (`request` in `src/services/parameters.js`), 60 s for an exporter's action, for a calibration put in force, which the unit answers once taken, and for the deletion of the calibration in use, which it answers once back on the firmware's.

Each part of the page (top bar, menu, page, status bar) is an `OvcsRegion` from `@ovcs/ui`: when it throws while rendering, it says so with a Reload button and the other parts stay. When the unit answers another firmware revision than the first, as after an upload under the open page, the shared top bar offers to reload: the page compares the `revision` of `GET /api/firmware`, read again at each reconnection, with the first it read.

`src/stores/calibration.js` holds the calibration session and the calibration in use, from the `calibration` channel. `src/stores/parameters.js` holds the groups and parameters; the controls and the save bar are `OvcsParameterControl` and `OvcsSaveBar` from `@ovcs/ui/react`.

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision/README.md).
