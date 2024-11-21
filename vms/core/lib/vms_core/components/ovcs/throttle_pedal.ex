defmodule  VmsCore.Components.OVCS.ThrottlePedal do
  @moduledoc """
    CAN throttle pedal using an analogic one + a generic controller
  """
  import Ecto.Query
  use GenServer
  alias VmsCore.{
    Bus,
    Components.OVCS.GenericController,
    Models.ThrottleCalibration,
    Repo
  }
  require Logger
  alias Decimal, as: D

  @raw_max_throttle 16_383
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
    {:ok, raw_throttle_a} = GenericController.get_analog_value(state.controller, state.throttle_a_pin)
    {:ok, raw_throttle_b} = GenericController.get_analog_value(state.controller, state.throttle_b_pin)

    state =
      %{state | raw_throttle_a: raw_throttle_a, raw_throttle_b: raw_throttle_b}
      |> handle_throttle()
      |> emit_metrics()
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

  def emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_throttle, value: state.requested_throttle, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :throttle_calibration_status, value: state.throttle_calibration_status, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :raw_max_throttle, value: state.raw_max_throttle, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :high_raw_throttle_a, value: state.high_raw_throttle_a, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :high_raw_throttle_b, value: state.high_raw_throttle_b, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :low_raw_throttle_a, value: state.low_raw_throttle_a, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :low_raw_throttle_b, value: state.low_raw_throttle_b, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :raw_throttle_a, value: state.raw_throttle_a, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :raw_throttle_b, value: state.raw_throttle_b, source: __MODULE__})
    state
  end

  @impl true
  def handle_call(:enable_calibration_mode, _from, state) do
    {:reply, :ok, %{state | throttle_calibration_status: "started"}}
  end

  def handle_call(:disable_calibration_mode, _from, %{throttle_calibration_status: "in_progress"} = state) do
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
  def handle_call(:disable_calibration_mode, _from, state) do
    {:reply, :ok, %{state | throttle_calibration_status: "disabled"}}
  end

  def handle_call({:calibrate, _type}, _from, state) do
    case state.throttle_calibration_status do
      "disabled" ->
        {:reply, :ok, %{state | throttle_calibration_status: "started"}}
      _ ->
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
  end

  def calibrate(type) when type == "boundaries" do
    GenServer.call(__MODULE__, {:calibrate, type})
  end

  def enable_calibration_mode do
    GenServer.call(__MODULE__, :enable_calibration_mode)
  end

  def disable_calibration_mode do
    GenServer.call(__MODULE__, :disable_calibration_mode)
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

  def raw_max_throttle do
    @raw_max_throttle
  end
end
