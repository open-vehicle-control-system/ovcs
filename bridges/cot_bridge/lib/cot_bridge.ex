defmodule CotBridge.Config do
  @moduledoc """
  Per-vehicle configuration for `CotBridge`. Vehicles return one of
  these from their `c:CotBridge.cot_bridge_config/1` callback.

  Connection knobs:

    * `:tak_host` — TAK server hostname or IP the bridge streams to
      (required).
    * `:tak_port` — TAK server port (default `8087`, the usual
      plain-TCP CoT streaming input).
    * `:protocol` — `:tcp` (default), `:udp`, or `:tls`.
    * `:ssl_options` — extra `:ssl.connect/4` options merged in when
      `:protocol` is `:tls` (client `certfile:` / `keyfile:` /
      `cacertfile:`, `verify:`, …).

  Identity knobs (all optional — `CotBridge.children/0` derives the
  defaults from the active vehicle when left `nil`):

    * `:uid` — stable CoT event uid (default `"ovcs-<vehicle name>"`).
    * `:callsign` — marker label shown in WebTAK / ATAK (default the
      vehicle name).
    * `:cot_type` — CoT type of the marker (default `"a-f-G-E-V-C"`:
      atom / friendly / Ground / Equipment / Vehicle / Civilian).
    * `:team` / `:role` — TAK group shown to other clients (defaults
      `"Cyan"` / `"Team Member"`).

  Source knobs — one per CoT parameter, following the same
  source-module convention as the VMS composers. No parameter has a
  guaranteed owner (a GNSS receiver may or may not report altitude or
  a usable course), so each knob names the module whose bus messages
  feed it; `nil` (default) leaves the parameter unknown:

    * `:position_source` — module broadcasting `:vehicle_position`
      (lat/lon map, e.g. `VmsCore.Components.OVCS.Gnss`). Without it
      the bridge has nothing to publish.
    * `:altitude_source` — module broadcasting `:altitude` (m).
    * `:speed_source` — module broadcasting `:speed` (km/h, e.g. the
      vehicle's ABS driver).
    * `:heading_source` — module broadcasting `:heading` (degrees).
      Note a GNSS source reports course over ground (only meaningful
      in motion); a compass/IMU component can own this instead.

  Publishing knobs:

    * `:publish_interval_ms` — how often a position event is sent
      (default `1_000`).
    * `:stale_after_s` — stale horizon stamped on each event; TAK
      clients fade the marker once it passes (default `20`).
    * `:source_max_age_ms` — any source value older than this is
      treated as unknown again; a stale *position* stops publishing
      entirely, so a dead feed lets the marker go stale in WebTAK
      instead of freezing it at a phantom location (default
      `10_000`).
  """
  @enforce_keys [:tak_host]
  defstruct [
    :tak_host,
    tak_port: 8087,
    protocol: :tcp,
    ssl_options: [],
    uid: nil,
    callsign: nil,
    cot_type: "a-f-G-E-V-C",
    team: "Cyan",
    role: "Team Member",
    position_source: nil,
    altitude_source: nil,
    speed_source: nil,
    heading_source: nil,
    publish_interval_ms: 1_000,
    stale_after_s: 20,
    source_max_age_ms: 10_000
  ]

  @type t :: %__MODULE__{
          tak_host: String.t(),
          tak_port: :inet.port_number(),
          protocol: :tcp | :udp | :tls,
          ssl_options: keyword(),
          uid: String.t() | nil,
          callsign: String.t() | nil,
          cot_type: String.t(),
          team: String.t(),
          role: String.t(),
          position_source: module() | nil,
          altitude_source: module() | nil,
          speed_source: module() | nil,
          heading_source: module() | nil,
          publish_interval_ms: pos_integer(),
          stale_after_s: pos_integer(),
          source_max_age_ms: pos_integer()
        }
end

defmodule CotBridge do
  @moduledoc """
  Bridge library that publishes the vehicle's position as Cursor on
  Target (CoT) events to a TAK server, so the vehicle can be followed
  live from WebTAK / ATAK clients outside the vehicle. Hosted by the
  shared `bridges/firmware` Nerves image; vehicles opt in via their
  `bridge_firmwares/0` map.

  The bridge owns no data itself: every CoT parameter (position,
  altitude, speed, heading) is combined from the bus messages of the
  source component the vehicle names for it — a GNSS CAN component
  (see `VmsCore.Components.OVCS.Gnss`), the ABS driver, a position
  fetched from another device over Ethernet, … Each tick the freshest
  combination is rendered as a CoT `<event>` and streamed to the
  configured TAK endpoint; internet access is assumed on the device
  running this bridge.

      OvcsBus "messages"  ──▶ PositionTracker ──▶ Publisher ──▶ TakConnection ──▶ TAK server ──▶ WebTAK
        :vehicle_position     (combine per        (CoT XML)      (tcp/udp/tls)
        :altitude :speed       *_source knobs)
        :heading
  """
  @behaviour OvcsBridge

  @doc """
  Per-deployment config. Returns a `CotBridge.Config` struct. The
  vehicle module that bundles `CotBridge` in its `bridge_firmwares/0`
  must implement this callback (declared via `@behaviour CotBridge`).

  The arm tag (`:host` for `./ovcs run`, `:target` for the deployed
  Nerves firmware) lets the vehicle return a different TAK endpoint /
  protocol per environment — e.g. a `TAK_SERVER_HOST` env var on
  host, a baked-in server + client TLS certs on target.
  """
  @callback cot_bridge_config(:host | :target) :: CotBridge.Config.t()

  # See `RosBridge` for why `Mix.target()` must be read at
  # module-compile time rather than at runtime.
  @arm if Mix.target() == :host, do: :host, else: :target

  @impl OvcsBridge
  def children do
    vehicle = vehicle()
    config = with_identity_defaults(vehicle.cot_bridge_config(@arm), vehicle)

    [
      {CotBridge.TakConnection, config},
      {CotBridge.PositionTracker, config},
      {CotBridge.Publisher, config}
    ]
  end

  defp with_identity_defaults(config, vehicle) do
    %{
      config
      | uid: config.uid || "ovcs-#{vehicle.name()}",
        callsign: config.callsign || vehicle.name()
    }
  end

  # See `RosBridge.vehicle/0` for why fetch! rather than get_env.
  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
