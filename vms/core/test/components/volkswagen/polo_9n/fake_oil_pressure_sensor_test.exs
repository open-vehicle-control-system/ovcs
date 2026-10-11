defmodule VmsCore.Components.Volkswagen.Polo9N.FakeOilPressureSensorTest do
  @moduledoc "The relay follows the rpm across 800, and holds while the rpm is unknown."
  use ExUnit.Case, async: false
  alias VmsCore.Components.Volkswagen.Polo9N.FakeOilPressureSensor

  defmodule Controller do
    @moduledoc "Stands in for the generic controller and reports each relay change to the test."
    use GenServer

    def start_link(test_process), do: GenServer.start_link(__MODULE__, test_process)

    @impl GenServer
    def init(test_process), do: {:ok, test_process}

    @impl GenServer
    def handle_call({:set_digital_value, pin, enabled}, _from, test_process) do
      send(test_process, {:relay, pin, enabled})
      {:reply, :ok, test_process}
    end
  end

  defp tick(rotation_per_minute, enabled) do
    controller = start_supervised!({Controller, self()})

    state = %{
      controller: controller,
      relay_pin: 3,
      rotation_per_minute: rotation_per_minute,
      enabled: enabled
    }

    {:noreply, state} = FakeOilPressureSensor.handle_info(:loop, state)
    state.enabled
  end

  test "closes the relay at 800 rpm" do
    assert tick(800, false)
    assert_receive {:relay, 3, true}
  end

  test "opens the relay below 800 rpm" do
    refute tick(799, true)
    assert_receive {:relay, 3, false}
  end

  test "an unknown rpm leaves the relay open" do
    refute tick(nil, false)
    refute_receive {:relay, _pin, _enabled}
  end

  test "an unknown rpm leaves the relay closed" do
    assert tick(nil, true)
    refute_receive {:relay, _pin, _enabled}
  end
end
