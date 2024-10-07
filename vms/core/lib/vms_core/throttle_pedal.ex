defmodule VmsCore.ThrottlePedal do
  import Ecto.Query
  use GenServer
  alias VmsCore.{Repo, ThrottleCalibration}
  require Logger
  alias Decimal, as: D
  alias VmsCore.Bus


  @raw_max_throttle 16383
  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{controller: controller, throttle_a_pin: throttle_a_pin, throttle_b_pin: throttle_b_pin}) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    raw_throttle = %{
      high_raw_throttle_a: get_throttle_calibration_value_for_key("high_raw_throttle_a"),
      high_raw_throttle_b: get_throttle_calibration_value_for_key("high_raw_throttle_b"),
      low_raw_throttle_a: get_throttle_calibration_value_for_key("low_raw_throttle_a"),
      low_raw_throttle_b: get_throttle_calibration_value_for_key("low_raw_throttle_b")
    }

    {
      :ok, %{
        controller: controller,
        throttle_a_pin: throttle_a_pin,
        throttle_b_pin: throttle_b_pin,
        throttle_calibration_status: "disabled",
        raw_max_throttle: @raw_max_throttle,
        high_raw_throttle_a: raw_throttle.high_raw_throttle_a,
        high_raw_throttle_b: raw_throttle.high_raw_throttle_b,
        low_raw_throttle_a: raw_throttle.low_raw_throttle_a,
        low_raw_throttle_b: raw_throttle.low_raw_throttle_b,
        raw_throttle_a: 0,
        raw_throttle_b: 0,
        requested_throttle: @zero,
        calibrated: calibrated?(raw_throttle),
        loop_timer: timer
      }
    }
  end

  @impl true
  def handle_info(:loop, state) do
    {:ok, raw_throttle_a} = VmsCore.Controllers.GenericController.get_analog_value(state.controller, state.throttle_a_pin)
    {:ok, raw_throttle_b} = VmsCore.Controllers.GenericController.get_analog_value(state.controller, state.throttle_b_pin)

    state = handle_throttle(%{state | raw_throttle_a: raw_throttle_a, raw_throttle_b: raw_throttle_b})
    Bus.broadcast("messages", %Bus.Message{name: :requested_throttle, value: state.requested_throttle, source: __MODULE__})
    {:noreply, state}
  end

  defp handle_throttle(%{throttle_calibration_status: "started"} = state) do
    %{state |
      raw_max_throttle: @raw_max_throttle ,
      low_raw_throttle_a: @raw_max_throttle ,
      low_raw_throttle_b: @raw_max_throttle ,
      high_raw_throttle_a: 0,
      high_raw_throttle_b: 0,
      throttle_calibration_status: "in_progress",
      calibrated: false,
      requested_throttle: @zero
    }
  end
  defp handle_throttle(%{throttle_calibration_status: "in_progress"} = state) do
    %{state |
      low_raw_throttle_a: Enum.min([state.low_raw_throttle_a, state.raw_throttle_a]),
      low_raw_throttle_b: Enum.min([state.low_raw_throttle_b, state.raw_throttle_b]),
      high_raw_throttle_a: Enum.max([state.high_raw_throttle_a, state.raw_throttle_a]),
      high_raw_throttle_b: Enum.max([state.high_raw_throttle_b, state.raw_throttle_b]),
    }
  end
  defp handle_throttle(%{throttle_calibration_status: "disabled"} = state) do
    requested_throttle = case state.calibrated do
       false -> @zero
       true  ->
        D.sub(state.raw_throttle_a, state.low_raw_throttle_a)
        |> D.div(D.sub(state.high_raw_throttle_a, state.low_raw_throttle_a))
        |> D.round(2)
    end
    %{state | requested_throttle: requested_throttle}
  end

  @impl true
  def handle_call(:enable_throttle_calibration, _from, state) do
    {:reply, :ok, %{state | throttle_calibration_status: "started"}}
  end
  def handle_call(:disable_throttle_calibration, _from, %{throttle_calibration_status: "in_progress"} = state) do
    with  {:ok, _} <- set_throttle_calibration_value_for_key("low_raw_throttle_a", state.low_raw_throttle_a),
          {:ok, _} <- set_throttle_calibration_value_for_key("low_raw_throttle_b", state.low_raw_throttle_b),
          {:ok, _} <- set_throttle_calibration_value_for_key("high_raw_throttle_a", state.high_raw_throttle_a),
          {:ok, _} <- set_throttle_calibration_value_for_key("high_raw_throttle_b", state.high_raw_throttle_b)
    do
      {:reply, :ok, %{state | throttle_calibration_status: "disabled", calibrated: calibrated?(state)}}
    else
      {:error, error} -> {:error, error}
    end
  end
  def handle_call(:disable_throttle_calibration, _from, %{throttle_calibration_status: "started"} = state) do
    {:reply, :ok, %{state | throttle_calibration_status: "disabled"}}
  end
  def handle_call(:disable_throttle_calibration, _from, state) do
    {:reply, :ok, state}
  end

  def enable_throttle_calibration_mode() do
    GenServer.call(__MODULE__, :enable_throttle_calibration)
  end

  def disable_throttle_calibration_mode() do
    GenServer.call(__MODULE__, :disable_throttle_calibration)
  end

  defp get_throttle_calibration_value_for_key(key) do
    record = from(cc in ThrottleCalibration, where: cc.key == ^key, limit: 1, order_by: [desc: :inserted_at])
    |> Repo.one()
    Map.get(record || %{}, :value, 0)
  end

  defp set_throttle_calibration_value_for_key(key, value) do
    %ThrottleCalibration{key: key, value: value} |> Repo.insert()
  end

  defp calibrated?(state) do
    state.high_raw_throttle_a > state.low_raw_throttle_a && state.high_raw_throttle_b > state.low_raw_throttle_b
  end
end
