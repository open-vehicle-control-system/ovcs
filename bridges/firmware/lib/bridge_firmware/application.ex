defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{OvcsBridge.Supervisor, []}],
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end
end
