defmodule Ovcs1.Vms.ComposerTest do
  @moduledoc "The VMS composer's arguments against the drivers that receive them."
  use ExUnit.Case, async: false

  alias Ovcs1.Vms.Composer
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

    assert state.manual_braking_source == VmsCore.Components.Bosch.IBoosterGen2
    assert state.radio_braking_source == OVCS.RadioControl.Throttle
  end

  for {level, steers_and_brakes} <- [manual: false, radio: true, ros: true] do
    test "steers and brakes automatically under #{inspect(level)}: #{steers_and_brakes}" do
      state = select(unquote(level))

      assert state.selected_control_level == unquote(level)
      assert not is_nil(state.requested_steering_source) == unquote(steers_and_brakes)
      assert not is_nil(state.requested_braking_source) == unquote(steers_and_brakes)
    end
  end

  # Ready and at a standstill; `:ros` is reached through `:radio`.
  defp select(level) do
    {:ok, state} = ControlLevel.init(child_arguments(ControlLevel))
    {:ok, :cancel} = :timer.cancel(state.loop_timer)

    ready =
      state
      |> deliver(:ready_to_drive, true, Ovcs1.Vms)
      |> deliver(:speed, Decimal.new(0), VmsCore.Components.Volkswagen.Polo9N.ABS)

    Enum.reduce(path(level), ready, fn level, state ->
      state
      |> deliver(:requested_control_level, level, OVCS.RadioControl.RequestedControlLevel)
      |> tick()
    end)
  end

  defp path(:ros), do: [:radio, :ros]
  defp path(level), do: [level]

  defp deliver(state, name, value, source) do
    {:noreply, state} =
      ControlLevel.handle_info(%OvcsBus.Message{name: name, value: value, source: source}, state)

    state
  end

  defp tick(state) do
    {:noreply, state} = ControlLevel.handle_info(:loop, state)
    state
  end
end
