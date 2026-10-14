defmodule OvcsMini.GeometryTest do
  @moduledoc """
  Keeps the URDF `OvcsMini` reads in step with the xacro it is expanded
  from, and every frame the car's bridges stamp placed on `base_link`.
  """
  use ExUnit.Case, async: false

  @xacro Path.expand("../description/ovcs_mini.urdf.xacro", __DIR__)

  defp urdf, do: OvcsVehicle.URDF.read!(Path.expand("../description/ovcs_mini.urdf", __DIR__))

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

  describe "the bridges stamp the URDF's links" do
    # robot_state_publisher places only the URDF's links on base_link.
    for {arm, simulation} <- [target: nil, host: "1"], firmware_id <- ["ros", "ros_perception"] do
      test "#{arm}#{simulation && " simulation"} #{firmware_id}" do
        if unquote(simulation), do: System.put_env("OVCS_SIM", unquote(simulation))
        on_exit(fn -> System.delete_env("OVCS_SIM") end)

        %RosBridge.Config{components: components} =
          OvcsMini.ros_bridge_config(unquote(arm), unquote(firmware_id))

        stamped = stamped_frames(components)

        assert stamped != []
        assert Enum.reject(stamped, &(&1 in urdf_links())) == []
      end
    end

    defp urdf_links do
      %{joints: joints} = urdf()
      joints |> Map.values() |> Enum.flat_map(&[&1.parent, &1.child]) |> MapSet.new()
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

  describe "joint states" do
    test "the car's bridge publishes the URDF's moving joints" do
      %RosBridge.Config{components: components} = OvcsMini.ros_bridge_config(:target, "ros")
      {:ackermann_joint_states, opts} = List.keyfind(components, :ackermann_joint_states, 0)
      {left, right} = opts[:steering_joints]
      %{joints: joints} = urdf()

      moving = for {name, %{type: type}} <- joints, type != "fixed", into: MapSet.new(), do: name

      assert MapSet.new([left, right | opts[:wheel_joints]]) == moving
    end

    test "not against the simulator, which publishes its own" do
      System.put_env("OVCS_SIM", "1")
      on_exit(fn -> System.delete_env("OVCS_SIM") end)

      %RosBridge.Config{components: components} = OvcsMini.ros_bridge_config(:host, "ros")
      refute List.keymember?(components, :ackermann_joint_states, 0)
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
