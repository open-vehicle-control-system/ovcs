defmodule VisionCore.ComponentsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Components

  # A unit that gives up exits :shutdown; restarting it would spend the vision core's own budget.
  test "the stereo and detection units are not restarted once they give up" do
    for component <- [:detector, :stereo] do
      assert [%{restart: :transient}] = Components.start(component, [])
    end
  end

  # The vision core's supervisor refuses two children with one id.
  test "each detector's unit is a child of its own, identified by its pipeline's name" do
    for {component, opts, id} <- [
          {:detector, [], VisionCore.Detection.Supervisor},
          {:detector, [name: :road], VisionCore.Detection.Supervisor.Road},
          {:qnn_detector, [name: :signs], VisionCore.Detection.Supervisor.Signs},
          {:hailo_detector, [], VisionCore.Detection.Supervisor}
        ] do
      assert [%{id: ^id}] = Components.start(component, opts)
    end
  end

  test "the heartbeat and the simulator clock are not components: the ROS 2 exporter and the ros2: section own them" do
    for component <- [:heartbeat, :simulator_clock] do
      assert_raise FunctionClauseError, fn -> Components.start(component, []) end
    end
  end
end
