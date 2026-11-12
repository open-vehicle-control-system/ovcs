defmodule VmsCore.Status.Heartbeat do
  @moduledoc "Selects the heartbeat status from reset mode and the vehicle's status."
  @moduledoc safety: :relevant

  @doc "The next status to emit, or nil when it has not changed."
  def next_status(state) do
    cond do
      state.resetting && state.emitted_vms_status != "RESETTING" -> "RESETTING"
      state.emitted_vms_status != state.vms_status -> state.vms_status
      true -> nil
    end
  end
end
