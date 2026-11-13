defmodule SimulatorRunner.Application do
  @moduledoc """
  Starts the simulated hardware `config/runtime.exs` read from the
  vehicle, then prints the ready line `SimulatorRunner` documents.
  """
  use Application

  alias SimulatorRunner.Simulator

  @ready_line "OVCS simulator ready"

  @impl Application
  def start(_type, _args) do
    simulator = Application.fetch_env!(:simulator_runner, :simulator)
    children = [{SimulatorCore.Hardware, Simulator.hardware_options(simulator)}]

    with {:ok, supervisor} <-
           Supervisor.start_link(children,
             strategy: :one_for_one,
             name: SimulatorRunner.Supervisor
           ) do
      IO.puts(@ready_line)
      {:ok, supervisor}
    end
  end
end
