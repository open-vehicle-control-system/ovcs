defmodule VmsCore.Components.NetworkOptionTest do
  @moduledoc """
  Drivers write to the CAN network their `:network` option names, not
  to a fixed one.
  """
  use ExUnit.Case, async: false
  alias Cantastic.Interface
  alias VmsCore.Components.OVCS.SteeringColumn
  alias VmsCore.Components.Volkswagen.Polo9N.{Dashboard, PowerSteeringPump}

  @network :network_option_test

  defmodule EmitterRecorder do
    @moduledoc "Stands in for a Cantastic emitter and reports each request to the test."
    use GenServer

    def start_link({name, test_process}),
      do: GenServer.start_link(__MODULE__, {name, test_process}, name: name)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:update, fun}, _from, {name, test_process} = state) do
      send(test_process, {name, :update, fun.(%{"rotations_per_minute" => 0})})
      {:reply, :ok, state}
    end

    @impl GenServer
    def handle_cast(request, {name, test_process} = state) do
      send(test_process, {name, request})
      {:noreply, state}
    end
  end

  defp record_emitter(frame_name) do
    name = Interface.emitter_process_name(@network, frame_name)
    start_supervised!({EmitterRecorder, {name, self()}}, id: name)
    name
  end

  test "the power steering pump updates its engine_status frame on its network" do
    emitter = record_emitter("engine_status")
    state = %{network: @network, enabled: false, selected_gear: :drive}

    {:noreply, %{enabled: true}} = PowerSteeringPump.handle_info(:loop, state)
    assert_receive {^emitter, :update, %{"rotations_per_minute" => rotation_per_minute}}
    assert rotation_per_minute > 0
  end

  test "the Polo dashboard enables its engine_status frame on its network" do
    emitter = record_emitter("engine_status")
    state = %{network: @network, enabled: false, contact: :on}

    {:noreply, %{enabled: true}} = Dashboard.handle_info(:loop, state)
    assert_receive {^emitter, :enable}
  end

  test "the steering column gives its network to the dashboard actions" do
    assert {:reply, @network, _state} =
             SteeringColumn.handle_call(:network, self(), %{network: @network})
  end
end
