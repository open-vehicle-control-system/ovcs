defmodule VisionCore.Camera.Output do
  @moduledoc """
  One of a camera's named outputs: frames of one size, made at every
  frame of the camera, either by a `:processor` from the sensor's frame
  or scaled from another output with `:from`, each pixel the average of
  the block of that output's pixels it covers. A driver with named
  outputs (`c:VisionCore.Camera.outputs/1`) resolves its camera's
  `:outputs` here against the processors it has and the resolutions
  each can make:

      outputs: [
        view: [resolution: {2028, 1520}, processor: :cpu],
        inference: [resolution: {1014, 760}, from: :view]
      ]

  The first output in the configuration is the camera's default, the
  one a consumer that names no output takes (`VisionCore.Camera.Unit`).
  `:index` is the output's place among those the driver makes: an output
  scaled from another comes after it.
  """

  @enforce_keys [:name, :index, :width, :height]
  defstruct [:name, :index, :width, :height, processor: nil, from: nil]

  @type t :: %__MODULE__{
          name: atom(),
          index: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          processor: atom() | nil,
          from: atom() | nil
        }

  @typedoc "Each processor a driver has, with the resolutions it can make."
  @type processors :: %{atom() => [{pos_integer(), pos_integer()}]}

  @options [:resolution, :processor, :from]

  @doc """
  The outputs `outputs` describes, in its order, for a driver with
  `processors`; `{:error, message}` for one that cannot be made: none,
  a name given twice, an option it does not take, a missing or
  malformed `:resolution`, neither or both of `:processor` and `:from`,
  a processor the driver lacks or a resolution it cannot make, a `:from`
  naming no output, outputs whose `:from` runs in a cycle, or a size
  that is not a whole fraction of its source's.
  """
  @spec resolve(term(), processors()) :: {:ok, [t()]} | {:error, String.t()}
  def resolve(outputs, processors) do
    with :ok <- check_list(outputs),
         {:ok, described} <- describe_each(outputs, processors),
         :ok <- check_sources(described),
         {:ok, indices} <- indices(described),
         do: {:ok, Enum.map(described, &%{&1 | index: Map.fetch!(indices, &1.name)})}
  end

  @doc "`outputs` in the order of their indices, the order the driver makes them in."
  @spec port_order([t()]) :: [t()]
  def port_order(outputs), do: Enum.sort_by(outputs, & &1.index)

  defp check_list([]), do: {:error, "a camera has at least one output"}

  defp check_list(outputs) do
    cond do
      not (is_list(outputs) and Keyword.keyword?(outputs)) ->
        {:error, "outputs are a keyword list of named outputs, got #{inspect(outputs)}"}

      (twice = Keyword.keys(outputs) -- Enum.uniq(Keyword.keys(outputs))) != [] ->
        {:error,
         "outputs are named once each: #{Enum.map_join(Enum.uniq(twice), ", ", &"#{&1} twice")}"}

      true ->
        :ok
    end
  end

  defp describe_each(outputs, processors) do
    Enum.reduce_while(outputs, {:ok, []}, fn {name, options}, {:ok, described} ->
      case describe(name, options, processors) do
        {:ok, output} -> {:cont, {:ok, described ++ [output]}}
        {:error, message} -> {:halt, {:error, "output #{name}: #{message}"}}
      end
    end)
  end

  defp describe(name, options, processors) do
    with :ok <- check_options(options),
         {:ok, {width, height}} <- resolution(options[:resolution]),
         {:ok, maker} <- maker(options),
         :ok <- check_processor(maker, {width, height}, processors) do
      {:ok,
       %__MODULE__{
         name: name,
         index: nil,
         width: width,
         height: height,
         processor: maker[:processor],
         from: maker[:from]
       }}
    end
  end

  defp check_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      case Keyword.keys(options) -- @options do
        [] -> :ok
        [unknown | _rest] -> {:error, "no option #{inspect(unknown)}"}
      end
    else
      {:error, "its options are a keyword list, got #{inspect(options)}"}
    end
  end

  defp check_options(options),
    do: {:error, "its options are a keyword list, got #{inspect(options)}"}

  defp resolution({width, height} = resolution)
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: {:ok, resolution}

  defp resolution(other),
    do: {:error, "its :resolution is {width, height} in pixels, got #{inspect(other)}"}

  defp maker(options) do
    case Keyword.take(options, [:processor, :from]) do
      [{_kind, maker}] = taken when is_atom(maker) and not is_nil(maker) ->
        {:ok, taken}

      [processor: other] ->
        {:error, "its :processor is a processor's name, got #{inspect(other)}"}

      [from: other] ->
        {:error, "its :from is an output's name, got #{inspect(other)}"}

      _neither_or_both ->
        {:error, "it needs a :processor or a :from, not both"}
    end
  end

  defp check_processor([from: _source], _resolution, _processors), do: :ok

  defp check_processor([processor: processor], resolution, processors) do
    case Map.fetch(processors, processor) do
      :error ->
        {:error,
         "its processor #{inspect(processor)} is not one this driver has " <>
           "(#{processors |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)})"}

      {:ok, resolutions} ->
        if resolution in resolutions,
          do: :ok,
          else:
            {:error,
             "its processor #{inspect(processor)} cannot make #{size(resolution)}; " <>
               "it makes #{Enum.map_join(resolutions, " or ", &size/1)}"}
    end
  end

  defp check_sources(described) do
    by_name = Map.new(described, &{&1.name, &1})

    Enum.find_value(described, :ok, fn
      %{from: nil} ->
        nil

      %{from: from} = output ->
        case by_name do
          %{^from => source} ->
            with :ok <- whole_fraction(output, source), do: nil

          _no_source ->
            {:error,
             "output #{output.name}: its :from, #{inspect(from)}, is no output of the camera"}
        end
    end)
  end

  defp whole_fraction(output, source) do
    if output.width <= source.width and rem(source.width, output.width) == 0 and
         output.height <= source.height and rem(source.height, output.height) == 0,
       do: :ok,
       else:
         {:error,
          "output #{output.name}: #{size({output.width, output.height})} is no whole " <>
            "fraction of #{source.name}'s #{size({source.width, source.height})}"}
  end

  # Processors' outputs first, then each output scaled from one already numbered.
  defp indices(described) do
    {made, scaled} = Enum.split_with(described, &(&1.processor != nil))

    number(
      scaled,
      made |> Enum.with_index() |> Map.new(fn {output, index} -> {output.name, index} end)
    )
  end

  defp number([], indices), do: {:ok, indices}

  defp number(scaled, indices) do
    case Enum.split_with(scaled, &is_map_key(indices, &1.from)) do
      {[], unmade} ->
        {:error,
         "outputs #{Enum.map_join(unmade, ", ", & &1.name)} are made of none: " <>
           "their :from runs in a cycle"}

      {ready, waiting} ->
        indices =
          ready
          |> Enum.with_index(map_size(indices))
          |> Enum.reduce(indices, fn {output, index}, indices ->
            Map.put(indices, output.name, index)
          end)

        number(waiting, indices)
    end
  end

  defp size({width, height}), do: "#{width}x#{height}"
end
