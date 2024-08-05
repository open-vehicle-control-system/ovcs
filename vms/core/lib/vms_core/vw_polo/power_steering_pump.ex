defmodule VmsCore.VwPolo.PowerSteeringPump do
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver}

  @polo_network_name :polo_drive
  @abs_status_frame_name "abs_status"

  @network_name :misc
  @engine_status_frame_name "engine_status"

  @impl true
  def handle_info({:handle_frame,  %Frame{name: @abs_status_frame_name} = frame}, state) do
    :ok = Emitter.forward(@network_name, frame)
    {:noreply, state}
  end

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @engine_status_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      }
    })
    :ok = Receiver.subscribe(self(), @polo_network_name, @abs_status_frame_name)
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def rotation_per_minute(rotation_per_minute) do
    :ok = Emitter.update(@network_name, @engine_status_frame_name, fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
  end

  def on() do
    Emitter.enable(@network_name, @engine_status_frame_name)
  end

  def off() do
    Emitter.disable(@network_name, @engine_status_frame_name)
  end
end
