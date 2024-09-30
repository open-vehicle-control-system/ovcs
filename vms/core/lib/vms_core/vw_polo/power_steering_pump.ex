defmodule VmsCore.VwPolo.PowerSteeringPump do
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver}
  alias VmsCore.PubSub

  @impl true
  def init(_) do
    PubSub.subscribe("commands")
    :ok = Receiver.subscribe(self(), :polo_drive, "handbrake_status")
    :ok = Emitter.configure(:misc, "engine_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      },
      enable: true
    })
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "handbrake_status"} = frame}, state) do
    Emitter.forward(:misc, frame)
    {:noreply, state}
  end
  def handle_info(%PubSub.CommandMessage{name: :select_gear, value: selected_gear}, state) do
    case selected_gear do
      :parking -> rotation_per_minute(0)
      :drive   -> rotation_per_minute(1500)
      :reverse -> rotation_per_minute(1500)
    end
    {:noreply, state}
  end

  defp rotation_per_minute(rotation_per_minute) do
    :ok = Emitter.update(:misc, "engine_status", fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
  end
end
