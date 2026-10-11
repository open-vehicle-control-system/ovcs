defmodule Ovcs1.Vms.ComposerTuningTest do
  @moduledoc "The composer's tuning values reach the drivers and the dashboard."
  use ExUnit.Case, async: true

  alias Ovcs1.Vms.Composer
  alias Ovcs1.Vms.Composer.Dashboard.Blocks.TorqueChart
  alias VmsCore.Components.{Nissan.LeafAZE0, OVCS}

  defp child_arguments(module) do
    Enum.find_value(Composer.children(), fn
      {^module, arguments} -> arguments
      _child -> nil
    end)
  end

  test "the inverter and the torque chart share the maximum torques" do
    drive_max_torque_nm = Composer.inverter_drive_max_torque_nm()
    reverse_max_torque_nm = Composer.inverter_reverse_max_torque_nm()
    arguments = child_arguments(LeafAZE0.Inverter)

    assert {arguments.drive_max_torque_nm, arguments.reverse_max_torque_nm} ==
             {drive_max_torque_nm, reverse_max_torque_nm}

    [axis] = TorqueChart.definition(order: 0, full_width: false).y_axis
    assert {axis.min, axis.max} == {-reverse_max_torque_nm, drive_max_torque_nm}
  end

  test "the steering column is given its maximum angle" do
    assert child_arguments(OVCS.SteeringColumn).max_steering_angle_deg == 400
  end
end
