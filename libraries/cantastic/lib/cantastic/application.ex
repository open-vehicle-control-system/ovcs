defmodule Cantastic.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Cantastic.Interface

  @impl true
  def start(_type, _args) do
    can_network_specs = Application.get_env(:cantastic, :can_networks) |> String.split(",", trim: true)
    manual_setup      = Application.get_env(:cantastic, :manual_setup)
    frame_handler     = Application.get_env(:cantastic, :frame_handler)
    config            = frame_handler.can_config()

    interface_childen = Interface.configure_children(can_network_specs, manual_setup, frame_handler, config)

    children = [] ++ interface_childen
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cantastic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
