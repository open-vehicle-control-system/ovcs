defmodule VmsCore.Status do
  use GenServer
  require Logger

  alias Cantastic.{Emitter, ReceivedFrameWatcher, Frame, Signal}

  @network_name :ovcs
  @vms_status_frame_name "vms_status"
  @status_parameter "status"
  @counter_parameter "counter"
  @key_status_frame_name "key_status"
  @ready_to_drive_parameter "ready_to_drive"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @vms_status_frame_name, %{
      parameters_builder_function: &vms_status_frame_parameter_builder/1,
      initial_data: %{
        @status_parameter => "ok",
        @counter_parameter => 0,
        @ready_to_drive_parameter => false
      }
    })
    :ok = Emitter.enable(@network_name, @vms_status_frame_name)
    :ok = ReceivedFrameWatcher.subscribe(@network_name, ["contactors_status", "vms_relays_status", "car_controls_status"], self())
    :ok = Cantastic.Receiver.subscribe(self(), :polo_drive, @key_status_frame_name)
    :ok = ReceivedFrameWatcher.subscribe(:polo_drive, "abs_status", self())
    enable_watchers()
    {:ok, %{
      status: "ok",
      failed_frames: %{},
      frame_emitters: %{
        "contactors_status"   => "Contactors Ctrl",
        "vms_relays_status"   => "VMS Ctrl",
        "car_controls_status" => "Controls Ctrl",
        "abs_status"          => "ABS Ctrl"
      }
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_missing_frame,  network_name, frame_name}, state) do
    case state.failed_frames[frame_name] do
      nil ->
        Logger.warning("Frame #{network_name}.#{frame_name} not received anymore")
        Emitter.update(@network_name, @vms_status_frame_name, fn (data) ->
          %{data | @status_parameter => "failure"}
        end)
        state = state
        |> put_in([:status], "failure")
        |> put_in([:failed_frames, frame_name], %{emitter: state.frame_emitters[frame_name]})
        {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(@network_name, ["contactors_status", "vms_relays_status", "car_controls_status"])
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"key_state" => %Signal{value: key_status}} = signals
    case key_status do
      "off" ->
        :ok = ReceivedFrameWatcher.disable(:polo_drive, "abs_status")
      _ ->
        :ok = ReceivedFrameWatcher.enable(:polo_drive, "abs_status")
    end
    {:noreply, state}
  end

  defp vms_status_frame_parameter_builder(data) do
    counter    = data[@counter_parameter]
    parameters = data
    data       = %{data | @counter_parameter => VmsCore.NissanLeaf.Util.counter(counter + 1)}
    {:ok, parameters, data}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:failed_frames, _from, state) do
    {:reply, {:ok, state.failed_frames}, state}
  end

  @impl true
  def handle_call({:ready_to_drive, ready_to_drive}, _from, state) do
    :ok = Emitter.update(@network_name, @vms_status_frame_name, fn (data) ->
      %{data | @ready_to_drive_parameter => ready_to_drive}
    end)
    {:reply, :ok, state}
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def failed_frames() do
    GenServer.call(__MODULE__, :failed_frames)
  end

  def ready_to_drive(ready_to_drive) do
    GenServer.call(__MODULE__, {:ready_to_drive, ready_to_drive})
  end

  def enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end
end
