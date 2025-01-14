defmodule Complex.Kernel do
  @moduledoc """
  Provides operator overloading for Elixir operators.

  When you `use Complex.Kernel`, be aware that the arithmetic operators
  won't work in clause guards. For that you need to use the fully qualified
  functions (i.e.: `when Kernel.+(a, b) == 1`) instead.
  """

  # This is defined as such so that Elixir 1.12 formatters don't complain
  # and Elixir 1.13+ formatters don't remove the quotes from :"**" that
  # would make this work in Elixir <= 1.12
  @pow_atom String.to_atom("**")

  defmacro __using__(_) do
    operators = [{@pow_atom, 2}, +: 2, -: 2, /: 2, *: 2]

    quote do
      import Kernel, except: unquote(operators)
      import Complex.Kernel, only: unquote(operators)
    end
  end

  def a + b, do: Complex.add(a, b)
  def a - b, do: Complex.subtract(a, b)
  def a * b, do: Complex.multiply(a, b)
  def a / b, do: Complex.divide(a, b)

  def unquote(@pow_atom)(a, b), do: Complex.pow(a, b)
end
