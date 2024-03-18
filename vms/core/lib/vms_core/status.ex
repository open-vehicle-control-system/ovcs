defmodule VmsCore.Status do
  use GenServer
  require Logger

  alias Cantastic.{Emitter, ReceivedFrameWatcher}

  @network_name :ovcs
  @vms_status_frame_name "vms_status"
  @status_parameter "status"
  @counter_parameter "counter"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @vms_status_frame_name, %{
      parameters_builder_function: &vms_status_frame_parameter_builder/1,
      initial_data: %{
        @status_parameter => "ok",
        @counter_parameter => 0
      }
    })
    :ok = Emitter.enable(@network_name, @vms_status_frame_name)
    :ok = ReceivedFrameWatcher.subscribe(@network_name, ["contactors_status", "vms_relays_status", "car_controls_status"], self())
    enable_watchers()
    {:ok, %{
      status: "ok",
      failed_frames: %{},
      frame_emitters: %{
        "contactors_status" => "contactors_controller",
        "vms_relays_status" => "vms_controller",
        "car_controls_status" => "controls_controller"
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
        Emitter.update(@network_name, @vms_status_frame_name, fn (emitter_state) ->
          emitter_state |> put_in([:data, @status_parameter], "failure")
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

  defp vms_status_frame_parameter_builder(emitter_state) do
    counter = emitter_state.data[@counter_parameter]
    parameters = %{
      @status_parameter => emitter_state.data[@status_parameter],
      @counter_parameter => VmsCore.NissanLeaf.Util.counter(counter)
    }
    emitter_state = emitter_state |> put_in([:data, @counter_parameter], VmsCore.NissanLeaf.Util.counter(counter + 1))
    {:ok, parameters, emitter_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:failed_frames, _from, state) do
    {:reply, {:ok, state.failed_frames}, state}
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end

  def failed_frames() do
    GenServer.call(__MODULE__, :failed_frames)
  end

  def enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end
end
