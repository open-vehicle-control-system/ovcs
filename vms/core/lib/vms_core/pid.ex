defmodule VmsCore.PID do
  alias Decimal, as: D
  @zero D.new(0)

  defstruct kp: @zero,
            ki: @zero,
            kd: @zero,
            minimum_output: Decimal.new(-1),
            maximum_output: Decimal.new(1),
            minimum_elapsed_time: D.new("0.0001"),
            reset_derivative_when_setpoint_changes: false,
            proportional_term: @zero,
            integral_term: @zero,
            derivative_term: @zero,
            previous_time: nil,
            previous_error: nil,
            previous_measurement: nil,
            previous_setpoint: nil,
            output: nil

  def new(config \\ []) do
    default = %__MODULE__{}
    default |> Map.merge(config |> Enum.into(%{}))
  end

  def iterate(pid, measurement, setpoint) do
    time                 = System.monotonic_time(:millisecond)
    previous_time        = pid.previous_time || time
    elapsed_time_seconds = time |> D.sub(previous_time) |> D.div(1000) |> D.max(pid.minimum_elapsed_time)

    error          = setpoint |> D.sub(measurement)
    previous_error = cond do
      is_nil(pid.previous_error) -> error
      pid.reset_derivative_when_setpoint_changes && pid.previous_setpoint != setpoint -> error
      true -> pid.previous_error
    end

    proportional_term = error |> D.mult(pid.kp)
    integral_term     = error |> D.mult(elapsed_time_seconds) |> D.add(pid.integral_term) |> D.mult(pid.ki)
    derivative_term   = error |> D.sub(previous_error) |> D.div(elapsed_time_seconds) |> D.mult(pid.kd)
    output_raw        = proportional_term |> D.add(integral_term) |> D.add(derivative_term)
    output            = output_raw |> D.max(pid.minimum_output) |> D.min(pid.maximum_output)

    %{pid |
      previous_error: error,
      previous_time: time,
      previous_setpoint: setpoint,
      previous_measurement: measurement,
      proportional_term: proportional_term,
      integral_term: integral_term,
      derivative_term: derivative_term,
      output: output
    }
  end
end
