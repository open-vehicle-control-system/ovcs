defmodule VmsCore.Vehicles.OVCSMini do
  @moduledoc """
    Implements the OVCS Mini specific logic (when is the vehicle ready, ...)
  """
  use GenServer
  require Logger
  alias VmsCore.Bus
  alias Cantastic.ReceivedFrameWatcher

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    :ok = ReceivedFrameWatcher.subscribe(:ovcs, ["main_controller_alive"], self())
    enable_watchers()
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      ready_to_drive: false,
      vms_status: "ok",
      failed_frames: %{},
      frame_emitters: %{
        "main_controller_alive" => "Rear Ctrl"
      }
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> check_ready_to_drive()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_missing_frame,  network_name, frame_name}, state) do
    case state.failed_frames[frame_name] do
      nil ->
        Logger.warning("Frame #{network_name}.#{frame_name} not received anymore")
        state = state
          |> put_in([:vms_status], "failure")
          |> put_in([:failed_frames, frame_name], %{emitter: state.frame_emitters[frame_name]})
          {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(:ovcs, ["main_controller_alive"])
    {:noreply, state}
  end

  defp check_ready_to_drive(state) do
    #TODO
    state
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :vms_status, value: state.vms_status, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :failed_frames, value: state.failed_frames, source: __MODULE__})
    state
  end

  defp enable_watchers do
    Process.send_after(self(), :enable_watchers, 5000)
  end
end
