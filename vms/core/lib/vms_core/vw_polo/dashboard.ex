defmodule VmsCore.VwPolo.Dashboard do
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias VmsCore.PubSub

  @max_rotation_per_minute 10000

  @impl true
  def init(_) do
    :ok = Emitter.configure(:polo_drive, "engine_status", %{
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
    :ok = Emitter.update(:polo_drive, "engine_status", fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
    {:noreply, state}
  end

  def on() do
    Emitter.enable(:polo_drive, "engine_status")
  end

  def off() do
    Emitter.disable(:polo_drive, "engine_status")
  end
end
