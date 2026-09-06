defmodule VmsCore.StatusTest do
  @moduledoc """
  The boot reset. A VMS reboot always starves the generic controllers of
  the alive frame long enough for them to shut down, so the status
  process resets them once after boot, the way the dashboard action
  does. Driven through `handle_info/2` against a stub state: `init/1`
  configures Cantastic emitters, which do not exist under
  `mix test --no-start`.
  """
  use ExUnit.Case, async: true

  alias VmsCore.Status

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        vms_status: "OK",
        emitted_vms_status: "OK",
        ready_to_drive: false,
        emitted_ready_to_drive: false,
        ready_to_drive_source: Vms,
        vms_status_source: Vms,
        loop_timer: nil,
        resetting: false,
        reset_generic_controllers_frame_enabled: false
      },
      overrides
    )
  end

  test "the boot reset enters reset mode and schedules its own end" do
    {:noreply, state} = Status.handle_info(:start_reset_mode, state())
    assert state.resetting

    # The end is a message to self, so the process never blocks.
    assert_receive :stop_reset_mode, 1_500

    {:noreply, state} = Status.handle_info(:stop_reset_mode, state)
    refute state.resetting
  end
end
