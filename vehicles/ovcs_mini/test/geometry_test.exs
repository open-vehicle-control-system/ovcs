defmodule OvcsMini.GeometryTest do
  @moduledoc """
  Keeps the URDF `OvcsMini` reads in step with the xacro it is expanded
  from, and every frame the car's bridges stamp placed on `base_link`.
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
        way this test cannot check it any more and needs updating.
        """)
    end
  end

  describe "geometry/0, read off the URDF, matches the xacro" do
    for key <- [:wheelbase, :track, :wheel_radius, :steering_limit] do
      test "#{key}" do
        key = unquote(key)
        read = Map.fetch!(OvcsMini.geometry(), key)
        modelled = xacro_property(to_string(key))

        assert_in_delta read,
                        modelled,
                        1.0e-9,
                        "OvcsMini.geometry()[#{inspect(key)}] is #{read}, " <>
                          "but the xacro says #{modelled}: `mise run urdf`."
      end
    end

    test "every quantity is checked" do
      assert MapSet.new(Map.keys(OvcsMini.geometry())) ==
               MapSet.new([:wheelbase, :track, :wheel_radius, :steering_limit])
    end
  end

  describe "the simulated drivetrain agrees with the VMS and the simulated hardware" do
    test "the maximum motor current is the composer's" do
      assert xacro_property("max_motor_current") ==
               OvcsMini.Vms.Composer.drivetrain().max_motor_current
    end

    test "the acceleration per ampere is the simulated hardware's" do
      assert xacro_property("simulated_acceleration_per_ampere") ==
               OvcsMini.simulated_acceleration_per_ampere()
    end
  end

  describe "the car's bridges place every frame they stamp" do
    for firmware_id <- ["ros", "ros_perception"] do
      test firmware_id do
        %RosBridge.Config{components: components} =
          OvcsMini.ros_bridge_config(:target, unquote(firmware_id))

        {:static_transforms, transforms: transforms} =
          List.keyfind(components, :static_transforms, 0)

        placed = MapSet.new(transforms, & &1.child)
        stamped = stamped_frames(components)

        assert stamped != []
        assert Enum.reject(stamped, &(&1 in placed)) == []
      end
    end

    # `frame_id` options, the stereo unit's per side, and the IMU
    # publisher's default.
    defp stamped_frames(components) do
      for {component, opts} when is_list(opts) <- components,
          frame <- [
            opts[:frame_id],
            opts[:left][:frame_id],
            opts[:right][:frame_id],
            component == :imu_publisher && "imu_link"
          ],
          frame,
          do: frame
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
