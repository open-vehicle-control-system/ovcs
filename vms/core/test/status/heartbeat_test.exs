defmodule VmsCore.Status.HeartbeatTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias VmsCore.Status.Heartbeat

  test "reset mode dominates every vehicle status for consecutive ticks" do
    for status <- ["OK", "FAILURE"], emitted <- ["OK", "FAILURE", "RESETTING"] do
      state = %{resetting: true, vms_status: status, emitted_vms_status: emitted}
      next = Heartbeat.next_status(state) || emitted
      assert next == "RESETTING"
      assert Heartbeat.next_status(%{state | emitted_vms_status: next}) == nil
    end
  end

  test "leaving reset restores the latest vehicle status once" do
    for status <- ["OK", "FAILURE"] do
      state = %{resetting: false, vms_status: status, emitted_vms_status: "RESETTING"}
      assert Heartbeat.next_status(state) == status
      assert Heartbeat.next_status(%{state | emitted_vms_status: status}) == nil
    end
  end
end
