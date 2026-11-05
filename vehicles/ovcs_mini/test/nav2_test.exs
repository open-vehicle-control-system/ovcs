defmodule OvcsMini.Nav2Test do
  @moduledoc false
  use ExUnit.Case, async: false

  @directory Path.expand("../nav2", __DIR__)
  @urdf Path.expand("../description/ovcs_mini.urdf", __DIR__)

  setup do
    {:ok, configuration} = YamlElixir.read_from_file(Path.join(@directory, "nav2.yaml"))
    %{configuration: configuration}
  end

  test "navigation pose, twist and footprint refer to the rear axle", %{
    configuration: configuration
  } do
    joint = OvcsVehicle.URDF.read!(@urdf) |> OvcsVehicle.URDF.joint!("base_rear_axle_joint")
    {offset, 0.0, 0.0} = joint.xyz
    assert_in_delta offset, -OvcsMini.geometry().wheelbase / 2, 1.0e-9
    assert joint.parent == "base_link"

    for arm <- [:host, :target] do
      {:odometry_publisher, opts} =
        Enum.find(OvcsMini.ros_bridge_config(arm).components, fn
          {:odometry_publisher, _opts} -> true
          _ -> false
        end)

      assert opts[:base_frame_id] == joint.child
      assert opts[:base_ahead_of_rear_axle] == 0.0
      assert opts[:tf_frame_id] == joint.parent
      assert_in_delta opts[:tf_ahead_of_rear_axle], -offset, 1.0e-9
    end

    for name <- ["local_costmap", "global_costmap"] do
      costmap = configuration[name][name]["ros__parameters"]
      assert costmap["robot_base_frame"] == joint.child
      footprint = Jason.decode!(costmap["footprint"])
      chassis_x = Enum.map(footprint, fn [x, _y] -> x + offset end)
      assert_in_delta Enum.min(chassis_x), -0.30, 1.0e-9
      assert_in_delta Enum.max(chassis_x), 0.30, 1.0e-9
    end
  end

  test "each obstacle source has its own freshness deadline", %{configuration: configuration} do
    for name <- ["local_costmap", "global_costmap"] do
      costmap = configuration[name][name]["ros__parameters"]
      layers = Enum.map(costmap["plugins"], &costmap[&1])
      range_layers = Enum.filter(layers, &(&1["plugin"] == "nav2_costmap_2d::RangeSensorLayer"))
      assert length(range_layers) == 2

      assert Enum.all?(
               range_layers,
               &(length(&1["topics"]) == 1 and &1["no_readings_timeout"] > 0)
             )

      for layer <- layers,
          sources = layer["observation_sources"],
          not is_nil(sources),
          source <- String.split(sources) do
        assert layer[source]["expected_update_rate"] > 0
      end
    end
  end

  test "recovery requests fit the VMS speed floor and loaded action servers", %{
    configuration: configuration
  } do
    {_, motion_opts} =
      Enum.find(OvcsMini.Vms.Composer.children(), fn
        {VmsCore.Components.OVCS.RosVelocityCommand, _} -> true
        _ -> false
      end)

    behavior = configuration["behavior_server"]["ros__parameters"]

    for filename <- ["nav2_ackermann_bt.xml", "nav2_ackermann_through_poses_bt.xml"] do
      {tree, _} =
        filename
        |> then(&Path.join(@directory, &1))
        |> String.to_charlist()
        |> :xmerl_scan.file(quiet: true)

      assert :xmerl_xpath.string(~c"//Spin", tree) == []

      [{:xmlObj, :string, speed}] = [
        :xmerl_xpath.string(~c"string(//BackUp/@backup_speed)", tree)
      ]

      assert String.to_float(to_string(speed)) >= motion_opts.min_speed_m_s
      assert "backup" in behavior["behavior_plugins"]
    end

    assert behavior["backup"]["minimum_speed"] >= motion_opts.min_speed_m_s
  end
end
