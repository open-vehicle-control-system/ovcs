defmodule Cantastic.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Cantastic.Receiver

  @impl true
  def start(_type, _args) do
    can_network_specs = Application.get_env(:cantastic, :can_networks) |> String.split(",", trim: true)
    manual_setup      = Application.get_env(:cantastic, :manual_setup)
    frame_handler     = Application.get_env(:cantastic, :frame_handler)
    config            = frame_handler.can_config()
    signals_spec      = config["canSignals"]
    receivers = Enum.map(can_network_specs, fn (can_network_spec) ->
      [network_name, interface] = can_network_spec |> String.split(":")
      bitrate                   = config["canNetworks"][network_name]["bitrate"]
      process_name              = Receiver.process_name(network_name)
      Supervisor.child_spec({Receiver, [process_name, network_name, interface, bitrate, manual_setup, signals_spec, frame_handler]}, id: process_name)
    end)

    children = [
      {Cantastic.Interface, []}
    ] ++ receivers


    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cantastic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
