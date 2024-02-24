defmodule VmsCore.Controllers.ControlsController do
  use GenServer
  alias Cantastic.{Frame, Emitter}

  @network_name :drive
  @car_controls_status_frame_name "car_controls_status"

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), @network_name, ["car_controls_status"])
    {
      :ok, %{
        throttle: 0,
        calibration_status: "disabled",
        high_raw_throttle_a: get_calibration_value_for_key("high_raw_throttle_a"),
        high_raw_throttle_b: get_calibration_value_for_key("high_raw_throttle_b"),
        low_raw_throttle_a: get_calibration_value_for_key("low_raw_throttle_a"),
        low_raw_throttle_b: get_calibration_value_for_key("low_raw_throttle_b"),
      }
    }
  end

  def get_calibration_value_for_key(key) do
    import Ecto.Query
    record = from(cc in VmsCore.ControlsCalibration, where: cc.key == ^key, limit: 1, order_by: [desc: :inserted_at])
    |> VmsCore.Repo.all()
    |> List.first(%{})
    Map.get(record, :value, 0) # Returns 0 if no calibration data found
  end

  def compute_throttle_from_raw_value(value, state) do
    (trunc(value) - state.low_raw_throttle_a)/(state.high_raw_throttle_a - state.low_raw_throttle_a)
  end

  def enable_calibration_mode() do
    GenServer.call(__MODULE__, :enable_calibration);
  end

  def disable_calibration_mode() do
    GenServer.call(__MODULE__, :disable_calibration);
  end

  defp switch_calibration(enable) do
    case enable do
      true -> enable_calibration_mode()
      false -> disable_calibration_mode()
    end
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @car_controls_status_frame_name} = _frame, [raw_max_throttle, raw_throttle_a, raw_throttle_b, gear_requested] = _signals}, state) do
    state = case state.calibration_status do
      "started" ->
        %{state |
            throttle: 0,
            low_raw_throttle_a: trunc(raw_max_throttle.value),
            low_raw_throttle_b: trunc(raw_max_throttle.value),
            high_raw_throttle_a: 0,
            high_raw_throttle_b: 0,
            calibration_status: "in_progress"
          }
      "in_progress" ->
        %{state |
            throttle: 0,
            low_raw_throttle_a: Enum.min([state.low_raw_throttle_a, trunc(raw_throttle_a.value)]),
            low_raw_throttle_b: Enum.min([state.low_raw_throttle_b, trunc(raw_throttle_b.value)]),
            high_raw_throttle_a: Enum.max([state.high_raw_throttle_a, trunc(raw_throttle_a.value)]),
            high_raw_throttle_b: Enum.max([state.high_raw_throttle_b, trunc(raw_throttle_b.value)])
          }
      "disabled" ->
        throttle = if state.high_raw_throttle_a == 0 || state.high_raw_throttle_b == 0 do
          # Throttle has not been calibrated yet so no throttle, vms should be in "setup" mode
          0
        else
          compute_throttle_from_raw_value(raw_throttle_a.value, state)
        end
        IO.inspect state
        %{state | throttle: throttle}
    end
    {:noreply, state}
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, state.throttle, state}
  end

  def throttle() do
    GenServer.call(__MODULE__, :throttle)
  end

  def handle_call(:enable_calibration, _from, state) do
    {:reply, true, %{ state | calibration_status: "started" }}
  end

  def handle_call(:disable_calibration, _from, state) do
    if state.calibration_status == "in_progress" do
      low_raw_throttle_a = %VmsCore.ControlsCalibration{key: "low_raw_throttle_a", value: state.low_raw_throttle_a}
      low_raw_throttle_b = %VmsCore.ControlsCalibration{key: "low_raw_throttle_b", value: state.low_raw_throttle_b}
      high_raw_throttle_a = %VmsCore.ControlsCalibration{key: "high_raw_throttle_a", value: state.high_raw_throttle_a}
      high_raw_throttle_b = %VmsCore.ControlsCalibration{key: "high_raw_throttle_b", value: state.high_raw_throttle_b}
      VmsCore.Repo.insert(low_raw_throttle_a)
      VmsCore.Repo.insert(low_raw_throttle_b)
      VmsCore.Repo.insert(high_raw_throttle_a)
      VmsCore.Repo.insert(high_raw_throttle_b)
      IO.inspect state
    end
    {:reply, false, %{ state | calibration_status: "disabled" }}
  end
end
