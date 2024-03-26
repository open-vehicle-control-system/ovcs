defmodule InfotainmentCore.Status do
  use GenServer
  require Logger

  alias Cantastic.{Emitter, ReceivedFrameWatcher, Frame, Signal}

  @network_name :ovcs
  @infotainment_status_frame_name "infotainment_status"
  @vms_status_frame_name "vms_status"
  @gear_status_frame_name "gear_status"
  @requested_gear_parameter "requested_gear"
  @selected_gear_parameter "selected_gear"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @infotainment_status_frame_name, %{
      parameters_builder_function: &infotainment_status_frame_parameter_builder/1,
      initial_data: %{
        @requested_gear_parameter => "parking",
      }
    })
    :ok = Emitter.enable(@network_name, @infotainment_status_frame_name)
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @vms_status_frame_name, self())
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @gear_status_frame_name)
    enable_watchers()
    {:ok, %{
      requested_gear: "parking",
      selected_gear: "parking",
      last_gear_update_at: Time.utc_now()
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_missing_frame,  network_name, frame_name}, state) do
    Logger.warning("Frame #{network_name}.#{frame_name} is missing")
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{@selected_gear_parameter => %Signal{value: selected_gear}} = signals
    if selected_gear != state.requested_gear && Time.diff(Time.utc_now(), state.last_gear_update_at) > 2 do
      {:noreply, %{state | requested_gear: selected_gear}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(@network_name, @vms_status_frame_name)
    {:noreply, state}
  end

  @impl true
  def handle_call({:request_gear, gear}, _from, state) do
    :ok = Emitter.update(@network_name, @infotainment_status_frame_name, fn (data) ->
      %{data | @requested_gear_parameter => gear}
    end)
    {:reply, {:ok, gear}, %{state |
      requested_gear: gear,
      last_gear_update_at: Time.utc_now()
    }}
  end


  defp infotainment_status_frame_parameter_builder(data) do
    {:ok, data, data}
  end

  defp enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end

  def request_gear(gear) do
    GenServer.call(__MODULE__, {:request_gear, gear})
  end
end
