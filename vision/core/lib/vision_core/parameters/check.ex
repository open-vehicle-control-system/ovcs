defmodule VisionCore.Parameters.Check do
  @moduledoc """
  What a setting accepts, checked in one place: its type, then its range
  and step or its values, then the settings it must stay above or below.

  `VisionCore.Parameters` checks every value set through it with
  `value/3` and `order/2`. A stereo stage builds its settings in
  `init/2` with `init_settings/3`, and checks a change in
  `set_option/3` with `change_setting/4`, from its `option_specs/0`,
  which `VisionCore.Stereo.Parameters` declares to the registry through
  `constraint/1`. A stage therefore takes what the dashboard can set,
  and checks a composer's option as it checks a live change.
  `VisionCore.Stereo.Pipeline` refuses a key with `live_setting/2`
  before a stage's `set_option/3` sees it.

  A refusal says what the value must be and what it got,
  `must be from 0 to 78, got 79`; a stage's begins with the setting,
  `p1 must be from 0 to 78, got 79`. No value makes it raise.
  """

  alias VisionCore.Parameters
  alias VisionCore.Stereo.Stage

  # The largest finite double: a larger integer has no double to become.
  @max_double 1.7_976_931_348_623_157e308

  @typedoc """
  A setting a value must stay `:above` or `:below`, by name, with its
  value: `nil` when it is not known.
  """
  @type relation :: {:above | :below, {atom() | String.t(), term()}}

  @typedoc "A stage's settings by key, as its `option_specs/0` declares them."
  @type specs :: [{atom(), Stage.option_spec()}]

  @doc """
  Checks `value` against a setting's `type`, then its `constraint`:
  within its range and on its step, or among its values. A `:double`
  takes any number a double holds and returns it as a float.
  """
  @spec value(Parameters.type(), Parameters.constraint() | nil, term()) ::
          {:ok, term()} | {:error, String.t()}
  def value(type, constraint, value) do
    with :ok <- typed(type, value),
         :ok <- within(constraint, value),
         {:ok, converted} <- converted(type, value) do
      {:ok, converted}
    else
      {:error, expected} -> {:error, "must be #{expected}, got #{inspect(value)}"}
    end
  end

  @doc """
  Checks `value` against the settings it must stay above or below; one
  whose value is `nil` is not checked.
  """
  @spec order(term(), [relation()]) :: :ok | {:error, String.t()}
  def order(value, relations) do
    Enum.find_value(relations, :ok, fn {side, {other, other_value}} ->
      order_refusal(side, other, value, other_value)
    end)
  end

  @doc """
  The `t:VisionCore.Parameters.constraint/0` of a setting spec, a
  stage's or a camera control's: `nil` when any value of its type goes.
  """
  @spec constraint(%{required(:type) => Parameters.type(), optional(atom()) => term()}) ::
          Parameters.constraint() | nil
  def constraint(%{type: :bool}), do: %{kind: :bool}
  def constraint(%{values: values}), do: %{kind: :choices, values: values}

  def constraint(%{range: {min, max}} = spec),
    do: %{kind: :range, min: min, max: max, step: spec[:step]}

  def constraint(_spec), do: nil

  @doc """
  The settings a stage starts with: `defaults`, a value for every key of
  `specs`, with the keyword list `opts` over them, each checked against
  its spec and the settings it is ordered against. Refuses an option
  `specs` does not declare.
  """
  @spec init_settings(specs(), %{atom() => term()}, keyword()) ::
          {:ok, %{atom() => term()}} | {:error, String.t()}
  def init_settings(specs, defaults, opts) do
    with :ok <- keyword_list(opts),
         given = Keyword.keys(opts),
         :ok <- declared(specs, given),
         {:ok, values} <- checked(specs, Map.merge(defaults, Map.new(opts))),
         :ok <- ordered(specs, Enum.uniq(given ++ Keyword.keys(specs)), values),
         do: {:ok, values}
  end

  @doc """
  Refuses `key` unless it is one of the live settings in `specs`, saying
  whether it is not a setting or is fixed when the stage starts.
  """
  @spec live_setting(specs(), term()) :: :ok | {:error, String.t()}
  def live_setting(specs, key) do
    case List.keyfind(specs, key, 0) do
      nil -> not_a_setting(key)
      {key, %{applies: :build}} -> {:error, "#{key} is fixed when the stage starts"}
      {_key, _spec} -> :ok
    end
  end

  @doc """
  Checks a change of the live setting `key` to `value`, against its spec
  and the stage's settings in force, `values`: the value to store, or
  why it is refused, as `live_setting/2` refuses a key.
  """
  @spec change_setting(specs(), %{atom() => term()}, term(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def change_setting(specs, values, key, value) do
    with :ok <- live_setting(specs, key), do: checked_change(specs, values, key, value)
  end

  # typed/2, within/2 and converted/2 refuse with what the value must be.
  defp typed(:bool, value) when is_boolean(value), do: :ok
  defp typed(:integer, value) when is_integer(value), do: :ok
  defp typed(:double, value) when is_number(value), do: :ok
  defp typed(:string, value) when is_binary(value), do: :ok
  defp typed(type, _value), do: {:error, type_name(type)}

  defp type_name(:bool), do: "true or false"
  defp type_name(:integer), do: "an integer"
  defp type_name(:double), do: "a number"
  defp type_name(:string), do: "a string"
  defp type_name(type), do: "of type #{inspect(type)}"

  defp within(%{kind: :range, min: min, max: max}, value) when value < min or value > max,
    do: {:error, "from #{min} to #{max}"}

  defp within(%{kind: :range, min: min, step: step}, value) when is_number(step) and step > 0 do
    steps = (value - min) / step

    if abs(steps - round(steps)) < 1.0e-9,
      do: :ok,
      else: {:error, "a multiple of #{step} from #{min}"}
  end

  # A double's integer value counts as the float it becomes.
  defp within(%{kind: :choices, values: choices}, value) do
    if Enum.any?(choices, &(&1 == value)),
      do: :ok,
      else: {:error, "one of #{Enum.map_join(choices, ", ", &render_choice/1)}"}
  end

  defp within(_constraint, _value), do: :ok

  defp converted(:double, value) when abs(value) <= @max_double, do: {:ok, value * 1.0}
  defp converted(:double, _value), do: {:error, "a number a double can hold"}
  defp converted(_type, value), do: {:ok, value}

  defp render_choice(nil), do: inspect(nil)

  defp render_choice(choice) when is_binary(choice) or is_atom(choice) or is_number(choice),
    do: to_string(choice)

  defp render_choice(choice), do: inspect(choice)

  defp order_refusal(_side, _other, _value, nil), do: nil

  defp order_refusal(:above, other, value, other_value) when value <= other_value,
    do: {:error, "must be above #{other} (#{inspect(other_value)}), got #{inspect(value)}"}

  defp order_refusal(:below, other, value, other_value) when value >= other_value,
    do: {:error, "must be below #{other} (#{inspect(other_value)}), got #{inspect(value)}"}

  defp order_refusal(_side, _other, _value, _other_value), do: nil

  defp keyword_list(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "options must be a keyword list, got #{inspect(opts)}"}
  end

  defp declared(specs, keys) do
    case Enum.reject(keys, &List.keymember?(specs, &1, 0)) do
      [] -> :ok
      [key | _] -> not_a_setting(key)
    end
  end

  defp not_a_setting(key), do: {:error, "#{name(key)} is not a setting"}

  defp checked_change(specs, values, key, value) do
    spec = specs[key]

    with {:ok, value} <- value(spec.type, constraint(spec), value),
         :ok <- order(value, relations(specs, key, values)) do
      {:ok, value}
    else
      {:error, reason} -> {:error, "#{key} #{reason}"}
    end
  end

  defp checked(specs, values) do
    Enum.reduce_while(specs, {:ok, values}, fn {key, spec}, {:ok, values} ->
      case value(spec.type, constraint(spec), values[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
        {:error, reason} -> {:halt, {:error, "#{key} #{reason}"}}
      end
    end)
  end

  # A refusal names the first of `keys` out of order: an option given rather than a default.
  defp ordered(specs, keys, values) do
    Enum.find_value(keys, :ok, fn key ->
      case order(values[key], relations(specs, key, values)) do
        :ok -> nil
        {:error, reason} -> {:error, "#{key} #{reason}"}
      end
    end)
  end

  defp relations(specs, key, values) do
    above = for {^key, %{greater_than: other}} <- specs, do: {:above, {other, values[other]}}
    below = for {other, %{greater_than: ^key}} <- specs, do: {:below, {other, values[other]}}
    above ++ below
  end

  defp name(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp name(key), do: inspect(key)
end
