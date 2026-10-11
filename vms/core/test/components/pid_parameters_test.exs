defmodule VmsCore.Components.PidParametersTest do
  @moduledoc "Setting the PID gains of the drivers that close a loop."
  use ExUnit.Case, async: false
  alias Decimal, as: D
  alias VmsCore.Components.{Bosch.IBoosterGen2, OVCS.SteeringColumn}

  defmodule Recorder do
    @moduledoc "Stands in for a driver: forwards each call to the test and replies `:ok`."
    use GenServer

    def start_link({name, test_process}),
      do: GenServer.start_link(__MODULE__, test_process, name: name)

    @impl GenServer
    def init(test_process), do: {:ok, test_process}

    @impl GenServer
    def handle_call(request, _from, test_process) do
      send(test_process, {:called, request})
      {:reply, :ok, test_process}
    end
  end

  @gains %{kp: D.new("0.5"), ki: D.new("0.01"), kd: D.new("0.1")}

  for driver <- [IBoosterGen2, SteeringColumn] do
    describe "#{inspect(driver)}" do
      test "set_pid_parameters/1 sends the gains to the running driver" do
        start_supervised!({Recorder, {unquote(driver), self()}})

        assert unquote(driver).set_pid_parameters(@gains) == :ok
        assert_receive {:called, {:set_pid_parameters, @gains}}
      end

      test "the driver stores the gains" do
        state = %{kp: nil, ki: nil, kd: nil}

        assert {:reply, :ok, state} =
                 unquote(driver).handle_call({:set_pid_parameters, @gains}, self(), state)

        assert state == @gains
      end
    end
  end
end
