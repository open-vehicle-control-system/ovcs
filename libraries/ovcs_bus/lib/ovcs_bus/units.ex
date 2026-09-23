defmodule OvcsBus.Units do
  @moduledoc """
  The units a message's `:unit` may carry, one function per unit so a
  misspelt unit fails to compile instead of reaching a dashboard.
  """

  def ampere, do: "A"
  def celsius, do: "°C"
  def degree, do: "°"
  def degree_per_second, do: "°/s"
  # A share of a full range, 1 being all of it: a normalised request, a
  # curve parameter. Dashboards show it as a percentage.
  def fraction, do: "fraction"
  def gram_per_second, do: "g/s"
  def hertz, do: "Hz"
  def kilometre, do: "km"
  def kilometre_per_hour, do: "km/h"
  def kilopascal, do: "kPa"
  def litre_per_hour, do: "L/h"
  def metre_per_second, do: "m/s"
  def microsecond, do: "µs"
  def millilitre_per_second, do: "ml/s"
  def millimetre, do: "mm"
  def millisecond, do: "ms"
  def minute, do: "min"
  def newton_metre, do: "N·m"
  def pascal, do: "Pa"
  def percent, do: "%"
  def revolution_per_minute, do: "rpm"
  def second, do: "s"
  def volt, do: "V"
end
