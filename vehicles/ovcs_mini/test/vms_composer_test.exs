defmodule OvcsMini.Vms.ComposerTest do
  @moduledoc "The VMS composer's arguments against the drivers that receive them."
  use ExUnit.Case, async: false

  alias OvcsMini.Vms.Composer
  alias VmsCore.Components.OVCS
  alias VmsCore.Managers.ControlLevel

  defp child_arguments(module) do
    Enum.find_value(Composer.children(), fn
      {^module, arguments} -> arguments
      %{start: {^module, :start_link, [arguments]}} -> arguments
      _child -> nil
    end)
  end

  test "the control level manager starts with the braking sources" do
    {:ok, state} = ControlLevel.init(child_arguments(ControlLevel))
    {:ok, :cancel} = :timer.cancel(state.loop_timer)

    assert state.radio_braking_source == OVCS.RadioControl.Throttle
  end

  test "the reported steering angle converts back with the commanded one's sign" do
    assert child_arguments(OVCS.VehicleMotion).steering_sign ==
             child_arguments(OVCS.RosVelocityCommand).steering_sign
  end
end
