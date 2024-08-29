defmodule VmsCore.VwPolo.PowerSteeringPump do
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver}

  @polo_network_name :polo_drive
  @handbrake_status_frame_name "handbrake_status"

  @network_name :misc
  @engine_status_frame_name "engine_status"

  @impl true
  def handle_info({:handle_frame,  %Frame{name: @handbrake_status_frame_name} = frame}, state) do
    if state.on do
      :ok = Emitter.forward(@network_name, frame)
    end
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
    :ok = Receiver.subscribe(self(), @polo_network_name, @handbrake_status_frame_name)
    {:ok, %{on: false}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def rotation_per_minute(rotation_per_minute) do
    :ok = Emitter.update(@network_name, @engine_status_frame_name, fn (data) ->
      %{data | "engine_rotations_per_minute" => rotation_per_minute}
    end)
  end

  @impl true
  def handle_call(:on, _from, state) do
    Emitter.enable(@network_name, @engine_status_frame_name)
    {:reply, :ok, %{state | on: true}}
  end

  @impl true
  def handle_call(:off, _from, state) do
    Emitter.disable(@network_name, @engine_status_frame_name)
    {:reply, :ok, %{state | on: false}}
  end

  def on() do
    GenServer.call(__MODULE__, :on)
  end

  def off() do
    GenServer.call(__MODULE__, :off)
  end
end
