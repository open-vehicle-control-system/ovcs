defmodule SimulatorRunner.ApplicationTest do
  # Starts the named simulated hardware and reads the application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  # Reads and emits no frame, so no CAN bus is needed.
  defmodule Idle do
    @behaviour SimulatorCore.SimulatedComponent

    @impl SimulatorCore.SimulatedComponent
    def init(opts), do: {Map.new(opts), [], []}
  end

  setup do
    Application.put_env(:simulator_runner, :simulator, %{
      vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522, mass_kg: 2.41},
      simulated_components: [{Idle, []}],
      can_config_path: "can/simulator.yml",
      can_mapping: "ovcs:vcan0"
    })

    on_exit(fn -> Application.delete_env(:simulator_runner, :simulator) end)
  end

  test "is not ready before the simulated hardware starts" do
    refute SimulatorRunner.ready?()
  end

  test "is ready once the vehicle's simulated hardware runs" do
    {:ok, supervisor} = SimulatorRunner.Application.start(:normal, [])

    assert SimulatorRunner.ready?()

    Supervisor.stop(supervisor)
  end

  test "is not ready once the simulated hardware stops" do
    {:ok, supervisor} = SimulatorRunner.Application.start(:normal, [])
    Supervisor.stop(supervisor)

    refute SimulatorRunner.ready?()
  end
end
