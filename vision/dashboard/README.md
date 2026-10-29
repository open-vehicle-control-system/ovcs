# vision dashboard

Vue app for the vision unit: the left, right and depth previews, status cards, the runtime parameters (editable) and the active settings. It talks to [`vision_api`](../api) over HTTP and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision.md).
