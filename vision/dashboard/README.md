# vision dashboard

React app (Vite, Zustand, Tailwind over `@ovcs/ui`) for the vision unit: the status cards and the left, right and depth previews. It talks to [`vision_api`](../api) over HTTP and Phoenix Channels.

```sh
npm install
npm run dev        # http://localhost:5174, started by `./ovcs run <vehicle>`
npm run build      # into vision/api/priv/static
npm run test:unit
```

`vision/firmware/build.sh` runs the build before `mix firmware`. See [Vision unit](../../docs/vision.md).
