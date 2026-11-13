defmodule VisionCore.Options do
  @moduledoc """
  Checks of the options a process of the vision core is started with: a
  value it cannot run with is refused at start, in words naming the
  option, instead of raising on the first frame.
  """

  @doc """
  `opts`' `key`, `default` without it, when it is an integer from `least`
  on. Raises `ArgumentError` naming the option otherwise.
  """
  @spec integer!(keyword(), atom(), integer() | nil, integer()) :: integer()
  def integer!(opts, key, default, least) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= least ->
        value

      value ->
        raise ArgumentError,
              "its #{inspect(key)} is an integer from #{least} on, got #{inspect(value)}"
    end
  end

  @doc """
  `opts`' `key`, `default` without it, when it is a number. Raises
  `ArgumentError` naming the option otherwise.
  """
  @spec number!(keyword(), atom(), number()) :: number()
  def number!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) -> value
      value -> raise ArgumentError, "its #{inspect(key)} is a number, got #{inspect(value)}"
    end
  end
end
