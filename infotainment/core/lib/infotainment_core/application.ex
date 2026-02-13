defmodule InfotainmentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    vehicle_children = vehicle_composer().children()
    children = [
      InfotainmentCore.Repo,
      {InfotainmentCore.Temperature, []},
      {InfotainmentCore.TimeSettings, []}
    ] ++ vehicle_children

    opts = [strategy: :one_for_one, name: InfotainmentCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def vehicle_composer do
    InfotainmentCore.Vehicles
      |> Module.concat(Application.get_env(:infotainment_core, :vehicle))
      |> Module.concat(Composer)
  end
end
