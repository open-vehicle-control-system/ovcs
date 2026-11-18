defmodule OvcsVehicle.Application do
  @moduledoc """
  Applies a firmware's Wi-Fi mode through `OvcsVehicle.Wifi`, when its
  `config/runtime.exs` sets `:ovcs_vehicle, :wifi_mode`, with the
  `:wifi_networks` and `:wifi_hotspot_psk` its `config/target.exs` sets.

  It depends on no firmware app, so the mode applies once VintageNet runs,
  whether or not the firmware's own apps start. Without a mode it starts
  nothing, and `wlan0` keeps the firmware's VintageNet config.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(Application.get_all_env(:ovcs_vehicle)),
      strategy: :one_for_one,
      name: OvcsVehicle.Supervisor
    )
  end

  @doc "The children for the app env `env`: `OvcsVehicle.Wifi` when it sets `:wifi_mode`."
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(env) do
    case Keyword.fetch(env, :wifi_mode) do
      {:ok, mode} ->
        [
          {OvcsVehicle.Wifi,
           mode: mode,
           networks: Keyword.get(env, :wifi_networks, []),
           hotspot_psk: Keyword.get(env, :wifi_hotspot_psk)}
        ]

      :error ->
        []
    end
  end
end
