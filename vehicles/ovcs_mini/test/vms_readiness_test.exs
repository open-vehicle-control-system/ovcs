defmodule OvcsMini.VmsReadinessTest do
  use ExUnit.Case, async: true
  alias OvcsMini.Vms
  alias OvcsBus.Message

  @tag skip: "not met: TASK-102 requires controller health before Mini readiness"
  test "withdraws readiness after boot when the controller is absent" do
    OvcsBus.subscribe("messages")
    {:ok, state} = Vms.init(nil)
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    {:noreply, state} = Vms.handle_info(:finish_boot_period, state)
    {:noreply, _state} = Vms.handle_info(:loop, state)

    assert_receive %Message{source: Vms, name: :ready_to_drive, value: false}
  end
end
