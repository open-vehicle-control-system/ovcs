defmodule VmsCore.Components.OVCS.SteeringColumn.Tuning do
  @moduledoc """
  Validates live steering tuning before it enters the PID or input filter.
  PID gains are finite signed numbers; alpha is in [0, 1] and deadband
  is non-negative. Decimal's default parsing limits also apply.
  """
  @moduledoc safety: :relevant

  alias Decimal, as: D

  @doc "Returns a finite, valid setting or an error without raising on malformed input."
  def parse(parameter, raw) when parameter in ["kp", "ki", "kd", "alpha", "deadband"] do
    with {:ok, %D{coef: coefficient} = value} when is_integer(coefficient) <- cast(raw),
         true <- valid?(parameter, value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_tuning_value}
    end
  end

  def parse(_parameter, _raw), do: {:error, :invalid_tuning_parameter}

  defp cast(text) when is_binary(text), do: text |> String.trim() |> D.cast()
  defp cast(value), do: D.cast(value)

  defp valid?("alpha", value), do: D.gte?(value, 0) and D.lte?(value, 1)
  defp valid?("deadband", value), do: D.gte?(value, 0)
  defp valid?(_gain, _value), do: true
end
