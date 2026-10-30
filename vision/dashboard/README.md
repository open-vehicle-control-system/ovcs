# vision dashboard

React app (Vite, Zustand, Tailwind over `@ovcs/ui`) for the vision unit. It talks to [`vision_api`](../api) over HTTP (JSON:API) and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

The page is laid out for a laptop screen:

- the status cards across the top;
- below, on the left, the left and right camera previews and the depth preview;
- on the right, the parameters: the pipeline diagram, the selected box's panel and the save bar (Save, Discard, Reset all, Export).

The selected box is kept in the URL as `?box=<group id>` (`?box=stereo.disparity`). The parameters are polled every second, so values set by an automatic mode stay current.

`src/stores/parameters.js` holds the groups and parameters; the controls and the save bar are `OvcsParameterControl` and `OvcsSaveBar` from `@ovcs/ui/react`.

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision.md).
