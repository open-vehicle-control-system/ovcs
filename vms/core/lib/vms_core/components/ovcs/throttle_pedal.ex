defmodule VmsCore.Components.OVCS.ThrottlePedal do
  @moduledoc """
  A dual-track analog throttle pedal read through two analog pins of a
  generic controller.

  The request is track A's position between its calibrated low and
  high readings, published as `:requested_throttle`. The dashboard's
  `"calibrate_boundaries"` action starts a calibration, which records
  each track's lowest and highest raw reading while the pedal is swept,
  and a second call stores them in `VmsCore.Models.ThrottleCalibration`.
  The request stays zero until both tracks are calibrated.

  ## Options

    * `:controller` — the generic controller the pedal is wired to.
    * `:throttle_a_pin`, `:throttle_b_pin` — its analog pins.
  """
  import Ecto.Query
  use GenServer
  alias OvcsBus, as: Bus

  alias VmsCore.{
    Components.OVCS.GenericController,
    Models.ThrottleCalibration,
    Repo
  }

  require Logger
  alias Decimal, as: D

  # Full scale of the generic controller's 14-bit ADC.
  @raw_max_throttle 16_383
  @zero D.new(0)
  @one D.new(1)
  @loop_period_ms 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{
        controller: controller,
        throttle_a_pin: throttle_a_pin,
        throttle_b_pin: throttle_b_pin
      }) do
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    stored_calibration = %{
      high_raw_throttle_a: stored_calibration_value("high_raw_throttle_a"),
      high_raw_throttle_b: stored_calibration_value("high_raw_throttle_b"),
      low_raw_throttle_a: stored_calibration_value("low_raw_throttle_a"),
      low_raw_throttle_b: stored_calibration_value("low_raw_throttle_b")
    }

    {
      :ok,
      %{
        controller: controller,
        throttle_a_pin: throttle_a_pin,
        throttle_b_pin: throttle_b_pin,
        throttle_calibration_status: "disabled",
        raw_max_throttle: @raw_max_throttle,
        high_raw_throttle_a: stored_calibration.high_raw_throttle_a,
        high_raw_throttle_b: stored_calibration.high_raw_throttle_b,
        low_raw_throttle_a: stored_calibration.low_raw_throttle_a,
        low_raw_throttle_b: stored_calibration.low_raw_throttle_b,
        raw_throttle_a: 0,
        raw_throttle_b: 0,
        requested_throttle: @zero,
        calibrated: calibrated?(stored_calibration),
        loop_timer: timer
      }
    }
  end

  @impl GenServer
  def handle_info(:loop, state) do
    {:ok, raw_throttle_a} =
      GenericController.get_analog_value(state.controller, state.throttle_a_pin)

    {:ok, raw_throttle_b} =
      GenericController.get_analog_value(state.controller, state.throttle_b_pin)

    state =
      %{state | raw_throttle_a: raw_throttle_a, raw_throttle_b: raw_throttle_b}
      |> update_throttle()
      |> emit_metrics()

    {:noreply, state}
  end

  defp update_throttle(%{throttle_calibration_status: "started"} = state) do
    %{
      state
      | raw_max_throttle: @raw_max_throttle,
        low_raw_throttle_a: @raw_max_throttle,
        low_raw_throttle_b: @raw_max_throttle,
        high_raw_throttle_a: 0,
        high_raw_throttle_b: 0,
        throttle_calibration_status: "in_progress",
        calibrated: false,
        requested_throttle: @zero
    }
  end

  defp update_throttle(%{throttle_calibration_status: "in_progress"} = state) do
    %{
      state
      | low_raw_throttle_a: Enum.min([state.low_raw_throttle_a, state.raw_throttle_a]),
        low_raw_throttle_b: Enum.min([state.low_raw_throttle_b, state.raw_throttle_b]),
        high_raw_throttle_a: Enum.max([state.high_raw_throttle_a, state.raw_throttle_a]),
        high_raw_throttle_b: Enum.max([state.high_raw_throttle_b, state.raw_throttle_b])
    }
  end

  defp update_throttle(%{throttle_calibration_status: "disabled"} = state) do
    requested_throttle =
      case state.calibrated do
        false ->
          @zero

        true ->
          D.sub(state.raw_throttle_a, state.low_raw_throttle_a)
          |> D.div(D.sub(state.high_raw_throttle_a, state.low_raw_throttle_a))
          |> D.max(@zero)
          |> D.min(@one)
          |> D.round(2)
      end

    %{state | requested_throttle: requested_throttle}
  end

  @doc false
  def emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :throttle_calibration_status,
      value: state.throttle_calibration_status,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :throttle_calibration_ongoing,
      value: state.throttle_calibration_status != "disabled",
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :raw_max_throttle,
      value: state.raw_max_throttle,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :high_raw_throttle_a,
      value: state.high_raw_throttle_a,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :high_raw_throttle_b,
      value: state.high_raw_throttle_b,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :low_raw_throttle_a,
      value: state.low_raw_throttle_a,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :low_raw_throttle_b,
      value: state.low_raw_throttle_b,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :raw_throttle_a,
      value: state.raw_throttle_a,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :raw_throttle_b,
      value: state.raw_throttle_b,
      source: __MODULE__
    })

    state
  end

  @impl GenServer
  def handle_call(:enable_calibration_mode, _from, state) do
    {:reply, :ok, %{state | throttle_calibration_status: "started"}}
  end

  def handle_call(
        :disable_calibration_mode,
        _from,
        %{throttle_calibration_status: "in_progress"} = state
      ) do
    with {:ok, _} <-
           store_calibration_value("low_raw_throttle_a", state.low_raw_throttle_a),
         {:ok, _} <-
           store_calibration_value("low_raw_throttle_b", state.low_raw_throttle_b),
         {:ok, _} <-
           store_calibration_value(
             "high_raw_throttle_a",
             state.high_raw_throttle_a
           ),
         {:ok, _} <-
           store_calibration_value(
             "high_raw_throttle_b",
             state.high_raw_throttle_b
           ) do
      {:reply, :ok,
       %{state | throttle_calibration_status: "disabled", calibrated: calibrated?(state)}}
    else
      {:error, error} -> {:reply, {:error, error}, state}
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
        with {:ok, _} <-
               store_calibration_value(
                 "low_raw_throttle_a",
                 state.low_raw_throttle_a
               ),
             {:ok, _} <-
               store_calibration_value(
                 "low_raw_throttle_b",
                 state.low_raw_throttle_b
               ),
             {:ok, _} <-
               store_calibration_value(
                 "high_raw_throttle_a",
                 state.high_raw_throttle_a
               ),
             {:ok, _} <-
               store_calibration_value(
                 "high_raw_throttle_b",
                 state.high_raw_throttle_b
               ) do
          {:reply, :ok,
           %{state | throttle_calibration_status: "disabled", calibrated: calibrated?(state)}}
        else
          {:error, error} -> {:reply, {:error, error}, state}
        end
    end
  end

  @doc """
  Dashboard action `"calibrate_boundaries"`: starts a calibration, or
  stores the boundaries of the one in progress.
  """
  def trigger_action("calibrate_boundaries", _parameters) do
    GenServer.call(__MODULE__, {:calibrate, "calibrate_boundaries"})
  end

  @doc "Starts a calibration."
  def enable_calibration_mode do
    GenServer.call(__MODULE__, :enable_calibration_mode)
  end

  @doc "Ends the calibration, storing its boundaries when one is in progress."
  def disable_calibration_mode do
    GenServer.call(__MODULE__, :disable_calibration_mode)
  end

  defp stored_calibration_value(key) do
    record =
      from(calibration in ThrottleCalibration,
        where: calibration.key == ^key,
        limit: 1,
        order_by: [desc: :inserted_at]
      )
      |> Repo.one()

    Map.get(record || %{}, :value, 0)
  end

  defp store_calibration_value(key, raw_throttle) do
    %ThrottleCalibration{key: key, value: raw_throttle} |> Repo.insert()
  end

  defp calibrated?(state) do
    state.high_raw_throttle_a > state.low_raw_throttle_a &&
      state.high_raw_throttle_b > state.low_raw_throttle_b
  end

  @doc "The full-scale raw reading of a track."
  def raw_max_throttle do
    @raw_max_throttle
  end
end
