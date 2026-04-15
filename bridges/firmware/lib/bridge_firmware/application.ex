defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:firmware, :target) do
        :host -> []
        _ -> [{OvcsBridge.Supervisor, []}]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end
end
