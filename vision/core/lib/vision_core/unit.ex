defmodule VisionCore.Unit do
  @moduledoc """
  What the supervisors of the vision core's units share: a unit that
  fails to start is left down, with the reason logged, so the vision
  core starts without it; a unit's options are read from the
  configuration's components; and an option a unit does not take is
  refused in words.

  `VisionCore.Detection.Supervisor`, `VisionCore.Segmentation.Supervisor`
  and `VisionCore.Camera.Unit` are units.
  """
  require Logger

  @doc """
  Starts the supervisor `module` with `opts`, as
  `Supervisor.start_link/3` with `start_options`. `:ignore` when it
  fails to start, logged as `module` failing and `label` down, and why.
  """
  @spec start_contained(module(), keyword(), keyword(), String.t()) :: Supervisor.on_start()
  def start_contained(module, opts, start_options, label) do
    case Supervisor.start_link(module, opts, start_options) do
      {:error, reason} ->
        Logger.error("#{inspect(module)} failed to start, #{label} down: #{failure_text(reason)}")

        :ignore

      started ->
        started
    end
  end

  @doc "Why a unit failed to start, from its supervisor's `reason`: the exception's message when one was raised."
  @spec failure_text(term()) :: String.t()
  def failure_text({:shutdown, {:failed_to_start_child, _child, reason}}),
    do: failure_text(reason)

  def failure_text({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  def failure_text(reason) when is_binary(reason), do: reason
  def failure_text(reason), do: inspect(reason)

  @doc """
  The options of each unit `config`'s components start under the
  supervisor `module`, in config order, as `VisionCore.Components`
  resolves them.
  """
  @spec options_of(VisionCore.Config.t(), module()) :: [keyword()]
  def options_of(%VisionCore.Config{components: components}, module) do
    for component <- components,
        {name, opts} = if(is_atom(component), do: {component, []}, else: component),
        %{start: {^module, _function, [unit_opts]}} <- VisionCore.Components.start(name, opts),
        do: unit_opts
  end

  @doc """
  `:ok` when every option of `opts` is among `taken`. Raises
  `ArgumentError` otherwise, saying of each other option that the unit
  has none such, or what `hints` says of it: where it belongs.
  """
  @spec refuse_unknown!(keyword(), [atom()], %{optional(atom()) => String.t()}) :: :ok
  def refuse_unknown!(opts, taken, hints \\ %{}) do
    case Enum.uniq(Keyword.keys(opts)) -- taken do
      [] ->
        :ok

      refused ->
        raise ArgumentError,
              Enum.map_join(refused, "; ", &Map.get(hints, &1, "it has no option #{inspect(&1)}"))
    end
  end
end
