defmodule VmsCore.VwPolo.Dashboard do
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.PubSub

  @network_name :polo_drive

  @engine_status_frame_name "engine_status"
  @max_rotation_per_minute 10000

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @engine_status_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      }
    })
    PubSub.subscribe("metrics")
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(%PubSub.MetricMessage{name: :rotation_per_minute, value: rotation_per_minute}, state) do
    rotation_per_minute = case D.gt?(rotation_per_minute, @max_rotation_per_minute) do
      true  -> 0
      false -> rotation_per_minute
    end
    :ok = Emitter.update(@network_name, @engine_status_frame_name, fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
    {:noreply, state}
  end

  def on() do
    Emitter.enable(@network_name, @engine_status_frame_name)
  end

  def off() do
    Emitter.disable(@network_name, @engine_status_frame_name)
  end
end
