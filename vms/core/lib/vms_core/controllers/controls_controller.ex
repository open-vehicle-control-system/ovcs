defmodule VmsCore.Controllers.ControlsController do
  import Ecto.Query
  use GenServer
  alias Cantastic.{Receiver, Emitter, Frame, Signal}
  alias VmsCore.{Repo, ThrottleCalibration}
  require Logger
  alias Decimal, as: D

  @network_name :ovcs
  @controls_controller_status_frame_name "controls_controller_status"
  @controls_controller_pwm_request_frame_name "controls_controller_pwm_request"
  @controls_controller_request_frame_name "controls_controller_request"
  @selected_gear_frame_name "gear_status"
  @selected_gear "selected_gear"

  @steering_column_motor_step_duty_cycle "steering_column_motor_step_duty_cycle"
  @steering_column_motor_direction "steering_column_motor_direction"
  @min_steering_column_motor_step_duty_cycle 0 + 5
  @max_steering_column_motor_step_duty_cycle 4095 - 5
  @raw_max_throttle 16383

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Receiver.subscribe(self(), @network_name, @controls_controller_status_frame_name)
    :ok = Emitter.configure(@network_name, @controls_controller_pwm_request_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @steering_column_motor_step_duty_cycle => @min_steering_column_motor_step_duty_cycle,
      }
    })
    :ok = Emitter.configure(@network_name, @controls_controller_request_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @steering_column_motor_direction => "clockwise",
      }
    })
    :ok = Emitter.configure(@network_name, @selected_gear_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @selected_gear => "parking"
      }
    })
    :ok = Emitter.enable(@network_name, [
      @controls_controller_pwm_request_frame_name,
      @controls_controller_request_frame_name,
      @selected_gear_frame_name
    ])
    {
      :ok, %{
        steering_column_motor_direction: "clockwise",
        steering_column_motor_in_alarm: false,
        car_controls: %{
          throttle: 0,
          throttle_calibration_status: "disabled",
          raw_max_throttle: @raw_max_throttle,
          high_raw_throttle_a: get_throttle_calibration_value_for_key("high_raw_throttle_a"),
          high_raw_throttle_b: get_throttle_calibration_value_for_key("high_raw_throttle_b"),
          low_raw_throttle_a: get_throttle_calibration_value_for_key("low_raw_throttle_a"),
          low_raw_throttle_b: get_throttle_calibration_value_for_key("low_raw_throttle_b"),
          raw_throttle_a: 0,
          raw_throttle_b: 0,
        }
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: _signals}}, %{car_controls: %{throttle_calibration_status: "started"}} = state) do
    state = Map.replace(state, :car_controls, %{
      throttle: 0, # Makes sure no throttle during
      raw_max_throttle: @raw_max_throttle ,
      low_raw_throttle_a: @raw_max_throttle ,
      low_raw_throttle_b: @raw_max_throttle ,
      high_raw_throttle_a: 0,
      high_raw_throttle_b: 0,
      raw_throttle_a: 0,
      raw_throttle_b: 0,
      throttle_calibration_status: "in_progress"
    })
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, %{car_controls: %{throttle_calibration_status: "in_progress"}} = state) do
    %{
      "raw_throttle_a" => %Signal{value: raw_throttle_a},
      "raw_throttle_b" => %Signal{value: raw_throttle_b}
    } = signals

    state = Map.replace(state, :car_controls, %{
      throttle: 0, # Makes sure no throttle during calibration
      raw_max_throttle: @raw_max_throttle,
      low_raw_throttle_a: Enum.min([state.car_controls.low_raw_throttle_a, raw_throttle_a]),
      low_raw_throttle_b: Enum.min([state.car_controls.low_raw_throttle_b, raw_throttle_b]),
      high_raw_throttle_a: Enum.max([state.car_controls.high_raw_throttle_a, raw_throttle_a]),
      high_raw_throttle_b: Enum.max([state.car_controls.high_raw_throttle_b, raw_throttle_b]),
      raw_throttle_a: 0,
      raw_throttle_b: 0,
      throttle_calibration_status: "in_progress"
    })
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, %{car_controls: %{throttle_calibration_status: "disabled"}} = state) do
    %{
      "raw_throttle_a" => %Signal{value: raw_throttle_a},
      "raw_throttle_b" => %Signal{value: raw_throttle_b},
      "steering_column_motor_direction" => %Signal{value: steering_column_motor_direction},
      "steering_column_motor_in_alarm" => %Signal{value: steering_column_motor_in_alarm}
    } = signals

    throttle = if state.car_controls.high_raw_throttle_a <= state.car_controls.low_raw_throttle_a || state.car_controls.high_raw_throttle_b <= state.car_controls.low_raw_throttle_b do
      Logger.warning("Throttle has not been calibrated yet or has calibration errors so no throttle, vms should force throttle calibration")
      0
    else
      compute_throttle_from_raw_value(raw_throttle_a, state)
    end
    state = state
      |> put_in([:steering_column_motor_direction], steering_column_motor_direction)
      |> put_in([:steering_column_motor_in_alarm], steering_column_motor_in_alarm)
      |> put_in([:car_controls, :throttle], throttle)
      |> put_in([:car_controls, :raw_throttle_a], raw_throttle_a)
      |> put_in([:car_controls, :raw_throttle_b], raw_throttle_b)
    {:noreply, state}
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, {:ok, state.car_controls.throttle}, state}
  end

  @impl true
  def handle_call(:enable_throttle_calibration, _from, state) do
    state = put_in(state, [:car_controls, :throttle_calibration_status], "started")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:car_controls_state, _from, state) do
    {:reply, {:ok, state.car_controls}, state}
  end

  @impl true
  def handle_call(:disable_throttle_calibration, _from, %{car_controls: %{throttle_calibration_status: "in_progress"}} = state) do
    with  {:ok, _} <- set_throttle_calibration_value_for_key("low_raw_throttle_a", state.car_controls.low_raw_throttle_a),
          {:ok, _} <- set_throttle_calibration_value_for_key("low_raw_throttle_b", state.car_controls.low_raw_throttle_b),
          {:ok, _} <- set_throttle_calibration_value_for_key("high_raw_throttle_a", state.car_controls.high_raw_throttle_a),
          {:ok, _} <- set_throttle_calibration_value_for_key("high_raw_throttle_b", state.car_controls.high_raw_throttle_b),
          {:ok, _} <- set_throttle_calibration_value_for_key("raw_max_throttle", state.car_controls.raw_max_throttle)

    do
      state = put_in(state, [:car_controls, :throttle_calibration_status], "disabled")
      {:reply, :ok, state}
    else
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def handle_call(:disable_throttle_calibration, _from, %{car_controls: %{throttle_calibration_status: "started"}} = state) do
    state = put_in(state, [:car_controls, :throttle_calibration_status], "disabled")
    {:reply, :ok, state}
  end
  @impl true
  def handle_call(:disable_throttle_calibration, _from, state) do
    {:reply, :ok, state}
  end

  def throttle() do
    GenServer.call(__MODULE__, :throttle)
  end

  def enable_throttle_calibration_mode() do
    GenServer.call(__MODULE__, :enable_throttle_calibration)
  end

  def disable_throttle_calibration_mode() do
    GenServer.call(__MODULE__, :disable_throttle_calibration)
  end

  def car_controls_state() do
    GenServer.call(__MODULE__, :car_controls_state)
  end

  defp get_throttle_calibration_value_for_key(key) do
    record = from(cc in ThrottleCalibration, where: cc.key == ^key, limit: 1, order_by: [desc: :inserted_at])
    |> Repo.one()
    Map.get(record || %{}, :value, 0) # Returns 0 if no calibration data found
  end

  defp set_throttle_calibration_value_for_key(key, value) do
    %ThrottleCalibration{key: key, value: value} |> Repo.insert()
  end

  def select_gear(gear) do
    :ok = Cantastic.Emitter.update(:ovcs, "gear_status", fn (data) ->
      %{data | @selected_gear => gear}
    end)
  end

  defp compute_throttle_from_raw_value(value, state) do
    D.sub(value, state.car_controls.low_raw_throttle_a)
    |> D.div(D.sub(state.car_controls.high_raw_throttle_a, state.car_controls.low_raw_throttle_a))
    |> D.round(2)
  end

  def set_steering_column_motor(duty_cycle, direction) do
    duty_cycle = max(@min_steering_column_motor_step_duty_cycle, duty_cycle)
      |> min(@max_steering_column_motor_step_duty_cycle)
    Emitter.update(@network_name, @controls_controller_pwm_request_frame_name, fn (data) ->
      %{data | @steering_column_motor_step_duty_cycle => duty_cycle}
    end)
    Emitter.update(@network_name, @controls_controller_request_frame_name, fn (data) ->
      %{data | @steering_column_motor_direction => direction}
    end)
  end
end
