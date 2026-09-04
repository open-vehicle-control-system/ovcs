defmodule OvcsMini.GeometryTest do
  @moduledoc """
  Keeps `OvcsMini.geometry/0` and the simulation model telling the same
  story.

  The vehicle's dimensions are declared twice and have to be: xacro
  cannot read Elixir, and the simulator needs them at
  model-generation time. Duplication is the price; this test is what
  stops it being silent.

  It is not a hypothetical. This model shipped with a wheel radius
  wrong by a factor of two — it drove convincingly and reported
  nonsense, and `/odom` could not catch it because the plugin's
  arithmetic cancels the radius out. A comparison of the two
  declarations catches that class of error in milliseconds, where the
  simulator needs a full drive to.
  """
  use ExUnit.Case, async: true

  @xacro Path.expand("../description/ovcs_mini.urdf.xacro", __DIR__)

  # `<xacro:property name="wheelbase" value="0.324" />`, tolerating
  # arbitrary whitespace and attribute order as written today.
  defp xacro_property(name) do
    source = File.read!(@xacro)

    case Regex.run(
           ~r/<xacro:property\s+name="#{name}"\s+value="([^"]+)"/,
           source
         ) do
      [_, value] ->
        {parsed, ""} = Float.parse(value)
        parsed

      nil ->
        flunk("""
        No <xacro:property name="#{name}"> in #{@xacro}.

        Either it was renamed, or the property is now computed. Either
        way this test cannot check it any more and needs updating —
        do not delete the assertion, because that is the check that
        keeps the two declarations honest.
        """)
    end
  end

  describe "geometry/0 agrees with the simulation model" do
    for key <- [:wheelbase, :track, :wheel_radius, :steering_limit] do
      test "#{key}" do
        key = unquote(key)
        declared = Map.fetch!(OvcsMini.geometry(), key)
        modelled = xacro_property(to_string(key))

        assert_in_delta declared,
                        modelled,
                        1.0e-9,
                        "OvcsMini.geometry()[#{inspect(key)}] is #{declared}, " <>
                          "but the xacro says #{modelled}. One of them is wrong; " <>
                          "measure the vehicle rather than picking a side."
      end
    end

    test "every measured quantity is checked" do
      # Guards against adding a field to geometry/0 and forgetting to
      # cover it here, which would reintroduce exactly the silent
      # duplication this file exists to prevent.
      assert MapSet.new(Map.keys(OvcsMini.geometry())) ==
               MapSet.new([:wheelbase, :track, :wheel_radius, :steering_limit])
    end
  end

  describe "derived values" do
    test "the minimum turning radius follows from the declared geometry" do
      # 0.324 / tan(0.52) = 0.5659 m. Stated here because it is the
      # bound every velocity command has to respect, and a change to
      # it should be visible in a diff rather than only in behaviour.
      assert_in_delta OvcsVehicle.min_turning_radius(OvcsMini.geometry()), 0.5659, 0.001
    end

    test "an Ackermann vehicle cannot rotate on the spot" do
      assert OvcsVehicle.max_yaw_rate(OvcsMini.geometry(), 0.0) == 0.0
    end

    test "the achievable yaw rate scales with speed" do
      geometry = OvcsMini.geometry()
      assert_in_delta OvcsVehicle.max_yaw_rate(geometry, 1.0), 1.767, 0.001
      assert_in_delta OvcsVehicle.max_yaw_rate(geometry, 2.0), 3.534, 0.001
    end
  end
end
