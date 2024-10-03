defmodule VmsCore.VwPolo.PowerSteeringPump do
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver}
  alias VmsCore.Bus

  @loop_period 10

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    :ok = Receiver.subscribe(self(), :polo_drive, "handbrake_status")
    :ok = Emitter.configure(:misc, "engine_status", %{
      parameters_builder_function: :default,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      },
      enable: true
    })
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      selected_gear: "parking"
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    case state.selected_gear do
      :parking -> rotation_per_minute(0)
      :drive   -> rotation_per_minute(1500)
      :reverse -> rotation_per_minute(1500)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: "handbrake_status"} = frame}, state) do
    Emitter.forward(:misc, frame)
    {:noreply, state}
  end
  def handle_info(%Bus.Message{name: :selected_gear, value: selected_gear}, state) do
    {:noreply, %{state | selected_gear: selected_gear}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp rotation_per_minute(rotation_per_minute) do
    :ok = Emitter.update(:misc, "engine_status", fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
  end
end
