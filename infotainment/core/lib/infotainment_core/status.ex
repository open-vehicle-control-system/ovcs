defmodule InfotainmentCore.Status do
  use GenServer
  require Logger

  alias Cantastic.{Emitter, ReceivedFrameWatcher, Frame, Signal}
  alias Decimal, as: D

  @network_name :ovcs
  @infotainment_status_frame_name "infotainment_status"
  @abs_status_frame_name "abs_status"
  @passenger_compartment_status_frame_name "passenger_compartment_status"
  @vms_status_frame_name "vms_status"
  @gear_status_frame_name "gear_status"
  @bms_status_frame_name "bms_status"
  @requested_gear_parameter "requested_gear"
  @selected_gear_parameter "selected_gear"
  @gear_selection_delay 1
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @infotainment_status_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @requested_gear_parameter => "parking",
      }
    })
    :ok = Emitter.enable(@network_name, @infotainment_status_frame_name)
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @vms_status_frame_name, self())
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, [
      @vms_status_frame_name,
      @gear_status_frame_name,
      @abs_status_frame_name,
      @passenger_compartment_status_frame_name,
      @bms_status_frame_name
    ])
    enable_watchers()
    {:ok, %{
      requested_gear: "parking",
      selected_gear: "parking",
      last_gear_update_at: Time.utc_now(),
      front_left_door_open: false,
      front_right_door_open: false,
      rear_left_door_open: false,
      rear_right_door_open: false,
      trunk_door_open: false,
      beam_active: false,
      handbrake_engaged: false,
      speed: @zero,
      ready_to_drive: false,
      state_of_charge: @zero,
      operating_mode: "power",
      instant_consumption: @zero,
      state_of_health: @zero,
      autonomy: @zero,
      charging_power: @zero
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
  def handle_info({:handle_frame, %Frame{name: @gear_status_frame_name, signals: signals}}, state) do
    %{@selected_gear_parameter => %Signal{value: selected_gear}} = signals
    state = if selected_gear != state.requested_gear && Time.diff(Time.utc_now(), state.last_gear_update_at) > @gear_selection_delay do
      :ok = Emitter.update(@network_name, @infotainment_status_frame_name, fn (data) ->
        %{data | @requested_gear_parameter => selected_gear}
      end)
      %{state | requested_gear: selected_gear}
    else
      state
    end
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @abs_status_frame_name, signals: signals}}, state) do
    %{"speed" => %Signal{value: speed}} = signals
    {:noreply, %{state | speed: speed}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @vms_status_frame_name, signals: signals}}, state) do
    %{"ready_to_drive" => %Signal{value: ready_to_drive}} = signals
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @passenger_compartment_status_frame_name, signals: signals}}, state) do
    %{
      "front_left_door_open" => %Signal{value: front_left_door_open},
      "front_right_door_open" => %Signal{value: front_right_door_open},
      "rear_left_door_open" => %Signal{value: rear_left_door_open},
      "rear_right_door_open" => %Signal{value: rear_right_door_open},
      "trunk_door_open" => %Signal{value: trunk_door_open},
      "beam_active" => %Signal{value: beam_active},
      "handbrake_engaged" => %Signal{value: handbrake_engaged}
    } = signals
    {:noreply, %{state |
        front_left_door_open: front_left_door_open,
        front_right_door_open: front_right_door_open,
        rear_left_door_open: rear_left_door_open,
        rear_right_door_open: rear_right_door_open,
        trunk_door_open: trunk_door_open,
        beam_active: beam_active,
        handbrake_engaged: handbrake_engaged
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @bms_status_frame_name, signals: signals}}, state) do
    %{
      "adaptative_state_of_charge" => %Signal{value: state_of_charge},
      "operating_mode" => %Signal{value: operating_mode},
      "instant_consumption" => %Signal{value: instant_consumption},
      "state_of_health" => %Signal{value: state_of_health},
      "autonomy" => %Signal{value: autonomy},
      "charging_power" => %Signal{value: charging_power}
    } = signals
    {:noreply, %{state |
        state_of_charge: state_of_charge,
        operating_mode: operating_mode,
        instant_consumption: instant_consumption,
        state_of_health: state_of_health,
        autonomy: autonomy,
        charging_power: charging_power
      }
    }
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
  @impl true
  def handle_call(:selected_gear, _from, state) do
    {:reply, {:ok, state.selected_gear}, state}
  end


  @impl true
  def handle_call(:speed, _from, state) do
    {:reply, {:ok, state.speed}, state}
  end

  @impl true
  def handle_call(:car_overview, _from, state) do
    overview = %{
      front_left_door_open: state.front_left_door_open,
      front_right_door_open: state.front_right_door_open,
      rear_left_door_open: state.rear_left_door_open,
      rear_right_door_open: state.rear_right_door_open,
      trunk_door_open: state.trunk_door_open,
      beam_active: state.beam_active,
      handbrake_engaged: state.handbrake_engaged,
      ready_to_drive: state.ready_to_drive
    }
    {:reply, {:ok, overview}, state}
  end

  defp enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end

  def request_gear(gear) do
    GenServer.call(__MODULE__, {:request_gear, gear})
  end

  def selected_gear() do
    GenServer.call(__MODULE__, :selected_gear)
  end

  def speed() do
    GenServer.call(__MODULE__, :speed)
  end

  def car_overview() do
    GenServer.call(__MODULE__, :car_overview)
  end
end
