defmodule VmsCore.Status.Heartbeat do
  @moduledoc "Selects the heartbeat status from reset mode and the vehicle's status."
  @moduledoc safety: :relevant

  @doc "The next status to emit, or nil when it has not changed."
  def next_status(state) do
    status = desired_status(state)
    if status != state.emitted_vms_status, do: status
  end

  defp desired_status(%{resetting: true}), do: "RESETTING"
  defp desired_status(%{vms_status: status}), do: status
end
