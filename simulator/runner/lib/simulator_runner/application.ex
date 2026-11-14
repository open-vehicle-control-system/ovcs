defmodule SimulatorRunner.Application do
  @moduledoc """
  Starts the simulated hardware `config/runtime.exs` read from the
  vehicle.
  """
  use Application

  alias SimulatorRunner.Simulator

  @impl Application
  def start(_type, _args) do
    simulator = Application.fetch_env!(:simulator_runner, :simulator)
    children = [{SimulatorCore.Hardware, Simulator.hardware_options(simulator)}]

    Supervisor.start_link(children, strategy: :one_for_one, name: SimulatorRunner.Supervisor)
  end
end
