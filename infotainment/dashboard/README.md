# Infotainment Dashboard (Flutter)

In-car touchscreen UI for the OVCS infotainment side. Flutter app targeting
Linux on the Raspberry Pi 5 head unit. Layout is driven entirely by
[`infotainment_api`](../api) — this project renders whatever pages +
blocks the active vehicle's `InfotainmentCore.Vehicle` composer exposes.

The firmware image (`../firmware`) bundles a cross-compiled build of this
app via `nerves_flutter_support`, so production devices ship the static
artifact — no live Flutter tooling on the Pi.

## Stack

- Flutter 3.32.8 (target platform: Linux desktop)
- [`phoenix_socket`](https://pub.dev/packages/phoenix_socket) — WebSocket
  client for the `/sockets/dashboard` channels
- `http` — REST client for the layout endpoints
- `google_fonts`, `flutter_svg`, `gauge_indicator`, `material_symbols_icons`

## Entry point & boot flow

1. `lib/main.dart` runs `MyApp` which mounts `_BootScreen`.
2. `_BootScreen` calls `ConfigService.fetchVehicle()` +
   `ConfigService.fetchPages()` against the REST API. Errors are surfaced
   with a retry button; success hands off to `InfotainmentShell`.
3. `InfotainmentShell` composes the page-level UI from the fetched config
   and subscribes to the `metrics` Phoenix channel through `MetricsService`
   (a `ChangeNotifier` that fans values out to block widgets).

Source layout:

```
lib/
├── main.dart                # MyApp + _BootScreen + theme
├── views/                   # InfotainmentShell + per-page views
├── components/              # Block widgets (gear selector, gauges, status grid, …)
├── models/                  # VehicleConfig, PageConfig, block models
└── services/                # ConfigService (REST), MetricsService (socket)
```

## Running locally

```sh
cd infotainment/dashboard
flutter pub get
flutter run -d linux
```

Expects `infotainment_api` at `http://localhost:4001`. Start it with
`./ovcs run <vehicle>` from the repo root, or
`cd infotainment/api && VEHICLE=Ovcs1 mix phx.server`.

## API connection

Currently hardcoded to `localhost:4001` in `ConfigService`. On a real
vehicle the Flutter app runs on the same Pi as `infotainment_api`, so
localhost resolves to the local Phoenix endpoint. Change
`lib/services/config_service.dart` if you need to point at a remote API
for desktop debugging.

## Production build

Done automatically inside the firmware release — `nerves_flutter_support`
invokes `flutter build linux` during `mix firmware` for the infotainment
firmware. You do not normally run it by hand.
