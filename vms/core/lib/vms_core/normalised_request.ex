defmodule VmsCore.NormalisedRequest do
  @moduledoc """
  Arithmetic on a request normalised to [-1, 1] — a throttle, a
  steering — shared by the components that shape one and the actuators
  that apply one.
  """
  alias Decimal, as: D

  @zero D.new(0)
  @one D.new(1)

  @doc """
  A request held to [-1, 1]: a commander that overshoots its range asks
  for full deflection, not for more than the actuator has.
  """
  def clamp(requested) do
    requested |> D.max(D.negate(@one)) |> D.min(@one)
  end

  @doc """
  The braking a signed request asks for, in [0, 1]: the magnitude of
  its negative half. A hand's single axis drives when positive and
  brakes when negative.
  """
  def braking(requested) do
    requested |> clamp() |> D.min(@zero) |> D.abs()
  end

  @doc """
  A magnitude given the sign of `reference`.
  """
  def signed_as(magnitude, reference) do
    if D.negative?(reference), do: D.negate(magnitude), else: magnitude
  end
end
