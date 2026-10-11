defmodule VmsCore.PID do
  alias Decimal, as: D

  @moduledoc """
  A proportional-integral-derivative controller in Decimal arithmetic,
  used by the component drivers that close a loop on a measurement.

  `new/1` takes the gains and limits; each `iterate/3` takes the latest
  measurement and setpoint and returns the controller with its new
  `output`, clamped to `[minimum_output, maximum_output]`.
  """
  require Logger

  @zero D.new(0)

  defstruct kp: @zero,
            ki: @zero,
            kd: @zero,
            minimum_output: D.new(-1),
            maximum_output: D.new(1),
            # Keeps the derivative finite when two iterations share a millisecond.
            minimum_elapsed_time: D.new("0.0001"),
            reset_derivative_when_setpoint_changes: false,
            proportional_term: @zero,
            error_integral: @zero,
            integral_term: @zero,
            derivative_term: @zero,
            previous_time: nil,
            previous_error: nil,
            previous_measurement: nil,
            previous_setpoint: nil,
            output: nil

  @doc """
  A controller with the struct's defaults overridden by `opts`, a keyword
  list of its fields (`kp`, `ki`, `kd`, output limits, ...).
  """
  def new(opts \\ []) do
    %__MODULE__{} |> Map.merge(opts |> Enum.into(%{}))
  end

  @doc """
  Advance the controller by one step towards `setpoint` from
  `measurement`, timed on the monotonic clock.
  """
  def iterate(pid, measurement, setpoint) do
    now_ms = System.monotonic_time(:millisecond)
    previous_time_ms = pid.previous_time || now_ms

    elapsed_time_s =
      now_ms
      |> D.sub(previous_time_ms)
      |> D.div(1000)
      |> D.max(pid.minimum_elapsed_time)

    error = setpoint |> D.sub(measurement)

    previous_error =
      cond do
        is_nil(pid.previous_error) -> error
        pid.reset_derivative_when_setpoint_changes && pid.previous_setpoint != setpoint -> error
        true -> pid.previous_error
      end

    proportional_term = error |> D.mult(pid.kp)

    error_integral = error |> D.mult(elapsed_time_s) |> D.add(pid.error_integral)
    integral_term = error_integral |> D.mult(pid.ki)

    derivative_term =
      error |> D.sub(previous_error) |> D.div(elapsed_time_s) |> D.mult(pid.kd)

    unclamped_output =
      proportional_term |> D.add(integral_term) |> D.add(derivative_term)

    output =
      unclamped_output |> D.max(pid.minimum_output) |> D.min(pid.maximum_output)

    Logger.debug(
      "E: #{error |> D.round(4)} - P: #{proportional_term |> D.round(4)} - I: #{integral_term |> D.round(4)} - D: #{derivative_term |> D.round(4)} - O: #{output |> D.round(4)}"
    )

    %{
      pid
      | previous_error: error,
        previous_time: now_ms,
        previous_setpoint: setpoint,
        previous_measurement: measurement,
        proportional_term: proportional_term,
        error_integral: error_integral,
        integral_term: integral_term,
        derivative_term: derivative_term,
        output: output
    }
  end
end
