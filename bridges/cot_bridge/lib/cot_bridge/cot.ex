defmodule CotBridge.Cot do
  @moduledoc """
  Renders Cursor on Target (CoT) `<event>` XML documents.

  Pure functions — no sockets, no processes — so the wire format can
  be unit-tested without a TAK server. Only the subset of CoT needed
  to place a vehicle on a WebTAK map is implemented: an `a-*` point
  event carrying `contact`, `__group`, `track`, and `takv` details.

  Caveats baked into the rendering:

    * `hae` is stamped with the GNSS altitude as-is. Consumer-grade
      receivers report MSL rather than height-above-ellipsoid; the
      few metres of geoid separation don't matter for tracking a
      vehicle on a map.
    * `ce` / `le` (circular / linear error) are stamped with the CoT
      "value unknown" sentinel — the GNSS frames don't carry accuracy
      estimates.
  """

  alias Decimal, as: D

  # CoT convention for "value not known" on hae/ce/le.
  @unknown "9999999.0"
  @kmh_per_ms D.new("3.6")

  @doc """
  Renders a position map (see `CotBridge.PositionTracker`) as a CoT
  event document. `:latitude` / `:longitude` are required in the map;
  `:altitude` (m), `:speed` (km/h) and `:heading` (degrees, true) are
  optional — absent or `nil` values degrade to the CoT unknowns.

  Options:

    * `:uid`, `:callsign`, `:cot_type`, `:team`, `:role` — event
      identity, all required (`CotBridge.children/0` fills them from
      the vehicle config).
    * `:stale_after_s` — seconds after `:now` at which TAK clients
      consider the event stale (default `20`).
    * `:now` — event time as a UTC `DateTime` (defaults to the
      current time; injectable for tests).
  """
  def position_event(position, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() end)
    stale = DateTime.add(now, Keyword.get(opts, :stale_after_s, 20), :second)

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<event version="2.0") <>
      ~s( uid="#{escape(Keyword.fetch!(opts, :uid))}") <>
      ~s( type="#{escape(Keyword.fetch!(opts, :cot_type))}") <>
      ~s( how="m-g") <>
      ~s( time="#{format_time(now)}") <>
      ~s( start="#{format_time(now)}") <>
      ~s( stale="#{format_time(stale)}">) <>
      point(position) <>
      detail(position, opts) <>
      ~s(</event>)
  end

  defp point(position) do
    ~s(<point lat="#{escape(position.latitude)}") <>
      ~s( lon="#{escape(position.longitude)}") <>
      ~s( hae="#{escape(position[:altitude] || @unknown)}") <>
      ~s( ce="#{@unknown}" le="#{@unknown}"/>)
  end

  defp detail(position, opts) do
    ~s(<detail>) <>
      ~s(<contact callsign="#{escape(Keyword.fetch!(opts, :callsign))}"/>) <>
      ~s(<__group name="#{escape(Keyword.fetch!(opts, :team))}") <>
      ~s( role="#{escape(Keyword.fetch!(opts, :role))}"/>) <>
      track(position) <>
      ~s(<takv device="#{escape(Keyword.fetch!(opts, :uid))}") <>
      ~s( platform="OVCS cot_bridge" os="Nerves" version="#{version()}"/>) <>
      ~s(</detail>)
  end

  # `track` carries speed in m/s and course in degrees true. Rendered
  # only when the position actually has a kinematic state — WebTAK
  # treats a missing element as "unknown" cleanly.
  defp track(position) do
    speed = position[:speed]
    heading = position[:heading]

    if is_nil(speed) and is_nil(heading) do
      ""
    else
      ~s(<track course="#{escape(heading || "0.0")}") <>
        ~s( speed="#{escape(kmh_to_ms(speed) || "0.0")}"/>)
    end
  end

  defp kmh_to_ms(nil), do: nil

  defp kmh_to_ms(kmh) do
    kmh
    |> to_decimal()
    |> D.div(@kmh_per_ms)
    |> D.round(2)
  end

  defp to_decimal(%D{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: D.new(value)
  defp to_decimal(value) when is_float(value), do: D.from_float(value)

  defp format_time(datetime) do
    datetime
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp version, do: (Application.spec(:cot_bridge, :vsn) || ~c"dev") |> to_string()
end
