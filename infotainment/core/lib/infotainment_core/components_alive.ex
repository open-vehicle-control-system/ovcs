defmodule InfotainmentCore.ComponentsAlive do
  use GenServer
  require Logger

  alias Cantastic.{ReceivedFrameWatcher, Frame, Signal}

  @network_name :ovcs
  @bms_status_frame_name "bms_status"
  @vms_status_frame_name "vms_status"
  @front_controller_alive_frame_name "front_controller_alive"
  @front_controller_status_frame_name "front_controller_digital_and_analog_pin_status"
  @rear_controller_alive_frame_name "rear_controller_alive"
  @controls_controller_alive_frame_name "controls_controller_alive"

  @impl true
  def init(_) do
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @bms_status_frame_name, self())
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @vms_status_frame_name, self())
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @front_controller_alive_frame_name, self())
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @front_controller_status_frame_name, self())
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @rear_controller_alive_frame_name, self())
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @controls_controller_alive_frame_name, self())
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, [
      @bms_status_frame_name,
      @vms_status_frame_name,
      @front_controller_alive_frame_name,
      @front_controller_status_frame_name,
      @rear_controller_alive_frame_name,
      @controls_controller_alive_frame_name
    ])
    enable_watchers()
    {:ok, %{
      bms_missing: true,
      vms_missing: true,
      inverter_missing: true,
      front_controller_missing: true,
      rear_controller_missing: true,
      controls_controller_missing: true
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_missing_frame,  _network_name, frame_name}, state) do
    #Logger.warning("Frame #{network_name}.#{frame_name} is missing")
    case frame_name do
      @bms_status_frame_name -> {:noreply, %{state | bms_missing: true}}
      @vms_status_frame_name -> {:noreply, %{state | vms_missing: true}}
      @front_controller_alive_frame_name -> {:noreply, %{state | front_controller_missing: true}}
      @front_controller_status_frame_name -> {:noreply, %{state | inverter_missing: true}}
      @rear_controller_alive_frame_name -> {:noreply, %{state | rear_controller_missing: true}}
      @controls_controller_alive_frame_name -> {:noreply, %{state | controls_controller_missing: true}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @front_controller_alive_frame_name, signals: _signals}}, state) do
    {:noreply, %{state | front_controller_missing: false}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @front_controller_status_frame_name, signals: signals}}, state) do
    %{
      "digital_pin3_enabled" => %Signal{value: inverter_enabled},
    } = signals
    {:noreply, %{state |
        inverter_missing: !inverter_enabled,
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @rear_controller_alive_frame_name, signals: _signals}}, state) do
    {:noreply, %{state | rear_controller_missing: false}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @controls_controller_alive_frame_name, signals: _signals}}, state) do
    {:noreply, %{state | controls_controller_missing: false}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @bms_status_frame_name, signals: _signals}}, state) do
    {:noreply, %{state | bms_missing: false}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @vms_status_frame_name, signals: _signals}}, state) do
    {:noreply, %{state | vms_missing: false}}
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(@network_name, @vms_status_frame_name)
    :ok = ReceivedFrameWatcher.enable(@network_name, @bms_status_frame_name)
    :ok = ReceivedFrameWatcher.enable(@network_name, @front_controller_alive_frame_name)
    :ok = ReceivedFrameWatcher.enable(@network_name, @front_controller_status_frame_name)
    :ok = ReceivedFrameWatcher.enable(@network_name, @rear_controller_alive_frame_name)
    :ok = ReceivedFrameWatcher.enable(@network_name, @controls_controller_alive_frame_name)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      bms_missing: state.bms_missing,
      vms_missing: state.vms_missing,
      front_controller_missing: state.front_controller_missing,
      inverter_missing: state.inverter_missing,
      rear_controller_missing: state.rear_controller_missing,
      controls_controller_missing: state.controls_controller_missing
    }
    {:reply, {:ok, status}, state}
  end

  defp enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end
end
