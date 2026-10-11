defmodule VmsCore.Components.Volkswagen.Polo9N.DashboardTest do
  @moduledoc "The rev counter shows the rpm, capped at the cluster's 6,000."
  use ExUnit.Case, async: false
  alias Cantastic.Interface
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Volkswagen.Polo9N.Dashboard

  @network :polo_dashboard_test

  defmodule EmitterRecorder do
    @moduledoc "Stands in for the `engine_status` emitter and reports the data written to it."
    use GenServer

    def start_link({name, test_process}),
      do: GenServer.start_link(__MODULE__, test_process, name: name)

    @impl GenServer
    def init(test_process), do: {:ok, test_process}

    @impl GenServer
    def handle_call({:update, fun}, _from, test_process) do
      send(test_process, {:engine_status, fun.(%{"rotations_per_minute" => 0})})
      {:reply, :ok, test_process}
    end
  end

  setup do
    name = Interface.emitter_process_name(@network, "engine_status")
    start_supervised!({EmitterRecorder, {name, self()}})
    :ok
  end

  defp displayed(rotation_per_minute) do
    state = %{
      network: @network,
      rotation_per_minute_source: Inverter
    }

    message = %Message{name: :rotation_per_minute, value: rotation_per_minute, source: Inverter}
    {:noreply, _state} = Dashboard.handle_info(message, state)
    assert_receive {:engine_status, %{"rotations_per_minute" => displayed}}
    D.to_integer(displayed)
  end

  test "an rpm within the cap is shown as is" do
    assert displayed(2_500) == 2_500
  end

  test "an rpm above the cap is shown at the cap" do
    assert displayed(7_200) == 6_000
  end

  test "an unknown rpm is shown as 0" do
    assert displayed(nil) == 0
  end
end
