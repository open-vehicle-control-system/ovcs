defmodule VmsCore.Speed do
  use GenServer
  alias VmsCore.Bus
  alias Decimal, as: D
  alias Cantastic.Emitter

  @loop_period 10
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{speed_source: speed_source}) do
    :ok = Emitter.configure(:ovcs, "abs_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "speed" => @zero,
      },
      enable: true
    })
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      speed_source: speed_source,
      emitted_speed: @zero,
      speed: @zero,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> adapt_speed()
    {:noreply, state}
  end

  def handle_info(%VmsCore.Bus.Message{name: :speed, value: speed, source: source}, state) when source == state.speed_source do
    {:noreply, %{state | speed: speed}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp adapt_speed(state) do
    case state.emitted_speed == state.speed do
      true -> state
      false ->
        :ok = Cantastic.Emitter.update(:ovcs, "abs_status", fn (data) ->
          %{data | "speed" => state.speed}
        end)
        %{state | emitted_speed: state.speed}
    end
  end
end
