defmodule VmsCore.Controllers.ControlsController do
  import Ecto.Query
  use GenServer
  alias Cantastic.{Receiver}
  alias VmsCore.{Repo, ControlsCalibration}

  @network_name :drive
  @car_controls_status_frame_name "car_controls_status"

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), @network_name, [@car_controls_status_frame_name])
    {
      :ok, %{
        throttle: 0,
        calibration_status: "disabled",
        raw_max_throttle: 0,
        high_raw_throttle_a: get_calibration_value_for_key("high_raw_throttle_a"),
        high_raw_throttle_b: get_calibration_value_for_key("high_raw_throttle_b"),
        low_raw_throttle_a: get_calibration_value_for_key("low_raw_throttle_a"),
        low_raw_throttle_b: get_calibration_value_for_key("low_raw_throttle_b"),
        requested_gear: "parking"
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, _frame, [raw_max_throttle | _] = _signals}, %{calibration_status: "started"} = state) do
   state = %{state |
      throttle: 0, # Makes sure no throttle during
      requested_gear: "parking",
      raw_max_throttle: raw_max_throttle.value,
      low_raw_throttle_a: trunc(raw_max_throttle.value),
      low_raw_throttle_b: trunc(raw_max_throttle.value),
      high_raw_throttle_a: 0,
      high_raw_throttle_b: 0,
      calibration_status: "in_progress"
    }
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, _frame, [_, raw_throttle_a, raw_throttle_b, _] = _signals}, %{calibration_status: "in_progress"} = state) do
    state = %{state |
      throttle: 0, # Makes sure no throttle during calibration
      requested_gear: "parking",
      low_raw_throttle_a: Enum.min([state.low_raw_throttle_a, trunc(raw_throttle_a.value)]),
      low_raw_throttle_b: Enum.min([state.low_raw_throttle_b, trunc(raw_throttle_b.value)]),
      high_raw_throttle_a: Enum.max([state.high_raw_throttle_a, trunc(raw_throttle_a.value)]),
      high_raw_throttle_b: Enum.max([state.high_raw_throttle_b, trunc(raw_throttle_b.value)])
    }
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, _frame, [_, raw_throttle_a, _raw_throttle_b, requested_gear] = _signals}, %{calibration_status: "disabled"} = state) do
    throttle = if state.high_raw_throttle_a <= state.low_raw_throttle_a || state.high_raw_throttle_b <= state.low_raw_throttle_b do
      # Throttle has not been calibrated yet or has calibration errors so no throttle, vms should force calibration
      0
    else
      compute_throttle_from_raw_value(raw_throttle_a.value, state)
    end
    state = %{state |
      throttle: throttle,
      requested_gear: requested_gear.value
    }
    {:noreply, state}
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, state.throttle, state}
  end

  @impl true
  def handle_call(:requested_gear, _from, state) do
    {:reply, state.requested_gear, state}
  end

  @impl true
  def handle_call(:enable_calibration, _from, state) do
    IO.inspect("Enable calibration")
    {:reply, true, %{ state | calibration_status: "started" }}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:disable_calibration, _from, %{calibration_status: "in_progress"} = state) do
    with {:ok, _} <- set_calibration_value_for_key("low_raw_throttle_a", state.low_raw_throttle_a),
          {:ok, _} <- set_calibration_value_for_key("low_raw_throttle_b", state.low_raw_throttle_b),
          {:ok, _} <- set_calibration_value_for_key("high_raw_throttle_a", state.high_raw_throttle_a),
          {:ok, _} <- set_calibration_value_for_key("high_raw_throttle_b", state.high_raw_throttle_b)
    do
      IO.inspect state
      {:reply, false, %{ state | calibration_status: "disabled" }}
    else
      {:error, error} -> {:error, error}
    end
  end

  def handle_call(:disable_calibration, _from, %{calibration_status: "started"} = state) do
    IO.inspect("Disable calibration")
    {:reply, false, %{ state | calibration_status: "disabled" }}
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

  defp get_calibration_value_for_key(key) do
    record = from(cc in ControlsCalibration, where: cc.key == ^key, limit: 1, order_by: [desc: :inserted_at])
    |> Repo.one()
    Map.get(record || %{}, :value, 0) # Returns 0 if no calibration data found
  end

  defp set_calibration_value_for_key(key, value) do
    %ControlsCalibration{key: key, value: value} |> Repo.insert()
  end

  defp compute_throttle_from_raw_value(value, state) do
    (trunc(value) - state.low_raw_throttle_a)/(state.high_raw_throttle_a - state.low_raw_throttle_a)
  end
end
