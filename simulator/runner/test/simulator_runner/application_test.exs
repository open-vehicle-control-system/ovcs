defmodule SimulatorRunner.ApplicationTest do
  # Starts the named simulated hardware and reads the application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :capture_log

  # Reads and emits no frame, so no CAN bus is needed; says when it starts.
  defmodule Probe do
    @behaviour SimulatorCore.SimulatedComponent

    @impl SimulatorCore.SimulatedComponent
    def init(opts) do
      IO.puts("component started")
      {Map.new(opts), [], []}
    end
  end

  setup do
    Application.put_env(:simulator_runner, :simulator, %{
      vehicle: %{wheelbase_m: 0.324, wheel_radius_m: 0.0522},
      simulated_components: [{Probe, []}],
      can_config_path: "can/simulator.yml",
      can_mapping: "ovcs:vcan0"
    })

    on_exit(fn -> Application.delete_env(:simulator_runner, :simulator) end)
  end

  test "starts the vehicle's simulated hardware, then prints the ready line" do
    output =
      capture_io(fn ->
        {:ok, supervisor} = SimulatorRunner.Application.start(:normal, [])
        Supervisor.stop(supervisor)
      end)

    assert output == "component started\nOVCS simulator ready\n"
  end
end
