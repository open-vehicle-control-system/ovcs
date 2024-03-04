defmodule VmsCore.Controllers.ControlsController do
  import Ecto.Query
  use GenServer
  alias Cantastic.{Receiver, Emitter}
  alias VmsCore.{Repo, ControlsCalibration}
  require Logger

  @network_name :ovcs
  @car_controls_status_frame_name "car_controls_status"
  @selected_gear_frame_name "gear_status"
  @selected_gear "selected_gear"
  @car_controls_update_interval_ms 500

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), @network_name, [@car_controls_status_frame_name])
    :ok = Emitter.configure(@network_name, @selected_gear_frame_name, %{
      parameters_builder_function: &gear_status_frame_parameters/1,
      initial_data: %{
        @selected_gear => "parking"
      }
    })
    :ok = Emitter.batch_enable(@network_name, [@selected_gear_frame_name])
    {
      :ok, %{
        car_controls: %{
          throttle: 0,
          calibration_status: "disabled",
          raw_max_throttle: 0,
          high_raw_throttle_a: get_calibration_value_for_key("high_raw_throttle_a"),
          high_raw_throttle_b: get_calibration_value_for_key("high_raw_throttle_b"),
          low_raw_throttle_a: get_calibration_value_for_key("low_raw_throttle_a"),
          low_raw_throttle_b: get_calibration_value_for_key("low_raw_throttle_b"),
          requested_gear: "parking",
        },
        last_dashboard_updated_at: :os.system_time(:millisecond),
        clients: [],
      }
    }
  end

  defp gear_status_frame_parameters(state) do
    {:ok, state.data, state}
  end

  @impl true
  def handle_cast({:subscribe, client}, state) do
    {:noreply, %{state | clients: [client | state.clients]}}
  end

  def subscribe(client) do
    GenServer.cast(__MODULE__, {:subscribe, client})
  end

  @impl true
  def handle_info({:handle_frame, _frame, [raw_max_throttle | _] = _signals}, %{car_controls: %{calibration_status: "started"}} = state) do
   state = Map.replace(state, :car_controls, %{
      throttle: 0, # Makes sure no throttle during
      requested_gear: "parking",
      raw_max_throttle: raw_max_throttle.value,
      low_raw_throttle_a: trunc(raw_max_throttle.value),
      low_raw_throttle_b: trunc(raw_max_throttle.value),
      high_raw_throttle_a: 0,
      high_raw_throttle_b: 0,
      calibration_status: "in_progress"
    })
    notify_clients(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, _frame, [_, raw_throttle_a, raw_throttle_b, _] = _signals}, %{car_controls: %{calibration_status: "in_progress"}} = state) do
    state = Map.replace(state, :car_controls, %{
      throttle: 0, # Makes sure no throttle during calibration
      requested_gear: "parking",
      low_raw_throttle_a: Enum.min([state.car_controls.low_raw_throttle_a, trunc(raw_throttle_a.value)]),
      low_raw_throttle_b: Enum.min([state.car_controls.low_raw_throttle_b, trunc(raw_throttle_b.value)]),
      high_raw_throttle_a: Enum.max([state.car_controls.high_raw_throttle_a, trunc(raw_throttle_a.value)]),
      high_raw_throttle_b: Enum.max([state.car_controls.high_raw_throttle_b, trunc(raw_throttle_b.value)]),
      calibration_status: "in_progress"
    })
    notify_clients(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, _frame, [_, raw_throttle_a, _raw_throttle_b, requested_gear] = _signals}, %{car_controls: %{calibration_status: "disabled"}} = state) do
    throttle = if state.car_controls.high_raw_throttle_a <= state.car_controls.low_raw_throttle_a || state.car_controls.high_raw_throttle_b <= state.car_controls.low_raw_throttle_b do
      Logger.warning("Throttle has not been calibrated yet or has calibration errors so no throttle, vms should force calibration")
      0
    else
      compute_throttle_from_raw_value(raw_throttle_a.value, state)
    end
    state = put_in(state, [:car_controls, :throttle], throttle) |> put_in([:car_controls, :requested_gear], requested_gear.value)
    notify_clients(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, state.car_controls.throttle, state}
  end

  @impl true
  def handle_call(:requested_gear, _from, state) do
    {:reply, state.car_controls.requested_gear, state}
  end

  @impl true
  def handle_call(:enable_calibration, _from, state) do
    state = put_in(state, [:car_controls, :calibration_status], "started")
    notify_clients(state)
    {:reply, :ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.car_controls, state}
  end

  def handle_call(:disable_calibration, _from, %{car_controls: %{calibration_status: "in_progress"}} = state) do
    with {:ok, _} <- set_calibration_value_for_key("low_raw_throttle_a", state.car_controls.low_raw_throttle_a),
          {:ok, _} <- set_calibration_value_for_key("low_raw_throttle_b", state.car_controls.low_raw_throttle_b),
          {:ok, _} <- set_calibration_value_for_key("high_raw_throttle_a", state.car_controls.high_raw_throttle_a),
          {:ok, _} <- set_calibration_value_for_key("high_raw_throttle_b", state.car_controls.high_raw_throttle_b)
    do
      state = put_in(state, [:car_controls, :calibration_status], "disabled")
      notify_clients(state)
      {:reply, :ok, state}
    else
      {:error, error} -> {:error, error}
    end
  end

  def handle_call(:disable_calibration, _from, %{car_controls: %{calibration_status: "started"}} = state) do
    state = put_in(state, [:car_controls, :calibration_status], "disabled")
    notify_clients(state)
    {:reply, :ok, state}
  end

  def select_gear(gear) do
    :ok = Emitter.update(@network_name, @selected_gear_frame_name, fn (state) ->
      state |> put_in([:data,  @selected_gear], gear)
    end)
  end

  def throttle() do
    GenServer.call(__MODULE__, :throttle)
  end

  def requested_gear() do
    GenServer.call(__MODULE__, :requested_gear)
  end

  def enable_calibration_mode() do
    GenServer.call(__MODULE__, :enable_calibration);
  end

  def disable_calibration_mode() do
    GenServer.call(__MODULE__, :disable_calibration);
  end

  def get_calibration_data() do
    GenServer.call(__MODULE__, :get_state);
  end

  def notify_clients(state) do
    now = :os.system_time(:millisecond)
    if (state.last_dashboard_updated_at + @car_controls_update_interval_ms) < now do
      state.clients |> Enum.each(fn (client) ->
        state = %{state | last_dashboard_updated_at: now}
        GenServer.cast(client, {:updated, state.car_controls})
      end)
    end
  end

  defp get_calibration_value_for_key(key) do
    record = from(cc in ControlsCalibration, where: cc.key == ^key, limit: 1, order_by: [desc: :inserted_at])
    |> Repo.one()
    Map.get(record || %{}, :value, 0) # Returns 0 if no calibration data found
  end

  defp set_calibration_value_for_key(key, value) do
    %ControlsCalibration{key: key, value: value} |> Repo.insert()
  end

  defp compute_throttle_from_raw_value(value, state) do
    Float.round(
      (trunc(value) - state.car_controls.low_raw_throttle_a)/(state.car_controls.high_raw_throttle_a - state.car_controls.low_raw_throttle_a),
      2
    )
  end
end
