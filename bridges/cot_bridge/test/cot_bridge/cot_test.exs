defmodule CotBridge.CotTest do
  use ExUnit.Case, async: true

  alias CotBridge.Cot
  alias Decimal, as: D

  @identity [
    uid: "ovcs-OVCS1",
    callsign: "OVCS1",
    cot_type: "a-f-G-E-V-C",
    team: "Cyan",
    role: "Team Member"
  ]

  @now ~U[2026-08-13 12:00:00.000Z]

  # The merged shape handed to Cot by PositionTracker: the GNSS
  # position plus the :speed (km/h) of the vehicle's speed component.
  defp position do
    %{
      latitude: D.new("50.8503000"),
      longitude: D.new("4.3517000"),
      altitude: D.new("56.0"),
      speed: D.new("36.00"),
      heading: D.new("90.00"),
      fix_type: :fix_3d,
      satellite_count: 12,
      timestamp: @now
    }
  end

  test "renders a well-formed CoT position event" do
    xml = Cot.position_event(position(), @identity ++ [now: @now, stale_after_s: 20])

    assert xml =~ ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>)

    assert xml =~
             ~s(<event version="2.0" uid="ovcs-OVCS1" type="a-f-G-E-V-C" how="m-g" ) <>
               ~s(time="2026-08-13T12:00:00.000Z" start="2026-08-13T12:00:00.000Z" ) <>
               ~s(stale="2026-08-13T12:00:20.000Z">)

    assert xml =~
             ~s(<point lat="50.8503000" lon="4.3517000" hae="56.0" ) <>
               ~s(ce="9999999.0" le="9999999.0"/>)

    assert xml =~ ~s(<contact callsign="OVCS1"/>)
    assert xml =~ ~s(<__group name="Cyan" role="Team Member"/>)
    assert xml =~ ~s(</event>)
  end

  test "converts track speed from km/h to m/s" do
    xml = Cot.position_event(position(), @identity ++ [now: @now])

    assert xml =~ ~s(<track course="90.00" speed="10.00"/>)
  end

  test "omits the track element when the position has no kinematic state" do
    position = position() |> Map.drop([:speed, :heading])
    xml = Cot.position_event(position, @identity ++ [now: @now])

    refute xml =~ "<track"
  end

  test "degrades a missing altitude to the CoT unknown sentinel" do
    xml = position() |> Map.put(:altitude, nil) |> Cot.position_event(@identity ++ [now: @now])

    assert xml =~ ~s(hae="9999999.0")
  end

  test "escapes XML-significant characters in identity attributes" do
    opts = Keyword.merge(@identity, callsign: ~s(A<B>&"C'), now: @now)
    xml = Cot.position_event(position(), opts)

    assert xml =~ ~s(callsign="A&lt;B&gt;&amp;&quot;C&apos;")
  end
end
