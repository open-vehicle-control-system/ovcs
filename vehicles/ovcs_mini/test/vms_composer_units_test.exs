defmodule OvcsMini.Vms.ComposerUnitsTest do
  @moduledoc "The VMS composer passes the vehicle's geometry under unit-named options."
  use ExUnit.Case, async: true

  alias OvcsMini.Vms.Composer
  alias VmsCore.Components.OVCS

  defp child_arguments(module) do
    Enum.find_value(Composer.children(), fn
      {^module, arguments} -> arguments
      %{start: {^module, :start_link, [arguments]}} -> arguments
      _child -> nil
    end)
  end

  test "the velocity command gets the wheelbase, steering limit and speeds" do
    arguments = child_arguments(OVCS.RosVelocityCommand)

    assert arguments.wheelbase_m == OvcsMini.geometry().wheelbase
    assert arguments.steering_limit_rad == OvcsMini.geometry().steering_limit
    assert arguments.max_speed_m_s > arguments.min_speed_m_s
  end

  test "the vehicle motion gets the wheel radius and steering limit" do
    arguments = child_arguments(OVCS.VehicleMotion)

    assert arguments.wheel_radius_m == OvcsMini.geometry().wheel_radius
    assert arguments.steering_limit_rad == OvcsMini.geometry().steering_limit
  end
end
