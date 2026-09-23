defmodule VmsCore.Throttle do
  @moduledoc """
  Arithmetic on a normalised throttle request, shared by the components
  that shape one and the actuators that apply one.
  """
  alias Decimal, as: D

  @one D.new(1)

  @doc """
  A request held to [-1, 1]: a commander that overshoots its range asks
  for full deflection, not for more than the actuator has.
  """
  def clamp(requested) do
    requested |> D.max(D.negate(@one)) |> D.min(@one)
  end

  @doc """
  A magnitude given the sign of `reference`.
  """
  def signed_as(magnitude, reference) do
    if D.negative?(reference), do: D.negate(magnitude), else: magnitude
  end
end
