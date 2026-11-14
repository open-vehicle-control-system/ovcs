defmodule VisionCore.Settings do
  @moduledoc """
  The settings of a pipeline that change while it runs: each declared
  once, as a spec with its `:type`, its `:range`, its `:default` and a
  `:description`, and checked against it at start and at each change
  (`VisionCore.Parameters.Check`), so a pipeline takes from its composer
  what its vision parameter takes.

  `VisionCore.Detection.Pipeline` and `VisionCore.Segmentation.Pipeline`
  hold theirs in the map they keep of their options, and declare them
  with `parameters/4` in groups that read them with `values/2`.
  """
  alias VisionCore.Parameters.Check

  @typedoc "A setting: its type, the values it takes, its value without an option, and what it is."
  @type spec :: %{
          type: VisionCore.Parameters.type(),
          range: {number(), number()},
          default: term(),
          description: String.t()
        }

  @type specs :: [{atom(), spec()}]

  @doc """
  The value of each setting of `specs` in `opts`, its default without
  one. Raises `ArgumentError` naming the option whose value its spec
  refuses.
  """
  @spec init!(specs(), keyword()) :: %{atom() => term()}
  def init!(specs, opts) do
    defaults = Map.new(specs, fn {key, spec} -> {key, spec.default} end)

    case Check.init_settings(specs, defaults, Keyword.take(opts, Keyword.keys(specs))) do
      {:ok, values} -> values
      {:error, reason} -> raise ArgumentError, "its :" <> reason
    end
  end

  @doc "`settings` with the setting `key` at `value`, or why `specs` refuse it."
  @spec put(specs(), map(), atom(), term()) :: {:ok, map()} | {:error, String.t()}
  def put(specs, settings, key, value) do
    with {:ok, value} <- Check.change_setting(specs, settings, key, value),
         do: {:ok, %{settings | key => value}}
  end

  @doc "The value of each setting of `specs` in `settings`, by its name."
  @spec values(specs(), map()) :: %{String.t() => term()}
  def values(specs, settings),
    do: Map.new(specs, fn {key, _spec} -> {Atom.to_string(key), Map.fetch!(settings, key)} end)

  @doc """
  The parameter declarations of the settings `keys` of `specs`, live,
  their default the value `settings` start with, each set with
  `set.(key, value)`. They have no `get`: their group reads them
  (`values/2`).
  """
  @spec parameters(specs(), [atom()], map(), (atom(), term() -> :ok | {:error, String.t()})) ::
          [VisionCore.Parameters.declaration()]
  def parameters(specs, keys, settings, set) do
    for key <- keys do
      spec = Keyword.fetch!(specs, key)

      %{
        name: Atom.to_string(key),
        type: spec.type,
        constraint: Check.constraint(spec),
        default: Map.fetch!(settings, key),
        description: spec.description,
        set: &set.(key, &1)
      }
    end
  end
end
