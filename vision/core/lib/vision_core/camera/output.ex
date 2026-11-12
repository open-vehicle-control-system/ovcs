defmodule VisionCore.Camera.Output do
  @moduledoc """
  One of a camera's named outputs: frames of one size, made at every
  frame of the camera, either by a `:processor` from the sensor's frame
  or scaled from another output with `:from`, each pixel the average of
  the block of that output's pixels it covers. A driver with named
  outputs (`c:VisionCore.Camera.outputs/1`) resolves its camera's
  `:outputs` here against the processors it has, the resolutions each
  can make and the formats it sends:

      outputs: [
        view: [resolution: {2028, 1520}, processor: :cpu],
        view_jpeg: [from: :view, format: :jpeg, quality: 80],
        inference: [resolution: {1014, 760}, from: :view]
      ]

  An output's `:format` is `:rgb`, frames of 8-bit red, green and blue
  pixels, by default, or `:jpeg` for an output made `:from` another:
  that output's image encoded by the driver, once a frame, at
  `:quality` 1 to 100 (80). An output made `:from` another has that
  output's `:resolution` unless it is given one.

  The first output in the configuration is the camera's default, the
  one a consumer that names no output takes (`VisionCore.Camera.Unit`).
  `:index` is the output's place among those the driver makes: an output
  scaled from another comes after it.
  """

  @enforce_keys [:name, :index, :width, :height]
  defstruct [
    :name,
    :index,
    :width,
    :height,
    processor: nil,
    from: nil,
    format: :rgb,
    quality: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          index: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          processor: atom() | nil,
          from: atom() | nil,
          format: :rgb | :jpeg,
          quality: 1..100 | nil
        }

  @typedoc "Each processor a driver has, with the resolutions it can make."
  @type processors :: %{atom() => [{pos_integer(), pos_integer()}]}

  @options [:resolution, :processor, :from, :format, :quality]
  @formats [:rgb, :jpeg]
  @default_quality 80

  @doc """
  The outputs `outputs` describes, in its order, for a driver with
  `processors` that sends the `:formats` of `options` (`[:rgb]`);
  `{:error, message}` for one that cannot be made: none, a name given
  twice, an option it does not take, a missing or malformed
  `:resolution`, neither or both of `:processor` and `:from`, a
  processor the driver lacks or a resolution it cannot make, a format
  it does not send, a JPEG made by a processor, a `:quality` outside 1
  to 100 or without `format: :jpeg`, a `:from` naming no output or a
  JPEG, outputs whose `:from` runs in a cycle, or a size that is not a
  whole fraction of its source's.
  """
  @spec resolve(term(), processors(), [{:formats, [:rgb | :jpeg]}]) ::
          {:ok, [t()]} | {:error, String.t()}
  def resolve(outputs, processors, options \\ []) do
    formats = Keyword.get(options, :formats, [:rgb])

    with :ok <- check_list(outputs),
         {:ok, described} <- describe_each(outputs, processors, formats),
         :ok <- check_sources_named(described),
         {:ok, indices} <- indices(described),
         sized = inherit_resolutions(described, indices),
         :ok <- check_sources(sized),
         do: {:ok, Enum.map(sized, &%{&1 | index: Map.fetch!(indices, &1.name)})}
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

  defp describe_each(outputs, processors, formats) do
    Enum.reduce_while(outputs, {:ok, []}, fn {name, options}, {:ok, described} ->
      case describe(name, options, processors, formats) do
        {:ok, output} -> {:cont, {:ok, described ++ [output]}}
        {:error, message} -> {:halt, {:error, "output #{name}: #{message}"}}
      end
    end)
  end

  defp describe(name, options, processors, formats) do
    with :ok <- check_options(options),
         {:ok, maker} <- maker(options),
         {:ok, {width, height}} <- resolution(options[:resolution], maker),
         {:ok, {format, quality}} <- format(options, maker, formats),
         :ok <- check_processor(maker, {width, height}, processors) do
      {:ok,
       %__MODULE__{
         name: name,
         index: nil,
         width: width,
         height: height,
         processor: maker[:processor],
         from: maker[:from],
         format: format,
         quality: quality
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

  defp resolution({width, height} = resolution, _maker)
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: {:ok, resolution}

  # Its source's, once the sources are numbered: `inherit_resolutions/2`.
  defp resolution(nil, from: _source), do: {:ok, {nil, nil}}

  defp resolution(other, _maker),
    do: {:error, "its :resolution is {width, height} in pixels, got #{inspect(other)}"}

  defp format(options, maker, formats) do
    format = Keyword.get(options, :format, :rgb)

    cond do
      format not in @formats ->
        {:error, "its :format is :rgb or :jpeg, got #{inspect(format)}"}

      format not in formats ->
        {:error,
         "its format #{inspect(format)} is not one this driver makes " <>
           "(#{Enum.map_join(formats, ", ", &inspect/1)})"}

      format == :rgb ->
        if Keyword.has_key?(options, :quality),
          do: {:error, "its :quality is a JPEG's: give it format: :jpeg"},
          else: {:ok, {:rgb, nil}}

      Keyword.has_key?(maker, :processor) ->
        {:error, "a JPEG is made :from another output, not by a :processor"}

      true ->
        jpeg_quality(Keyword.get(options, :quality, @default_quality))
    end
  end

  defp jpeg_quality(quality) when is_integer(quality) and quality in 1..100,
    do: {:ok, {:jpeg, quality}}

  defp jpeg_quality(other),
    do: {:error, "its :quality is an integer from 1 to 100, got #{inspect(other)}"}

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

  defp check_sources_named(described) do
    names = MapSet.new(described, & &1.name)

    Enum.find_value(described, :ok, fn
      %{from: nil} ->
        nil

      %{from: from} = output ->
        unless from in names,
          do:
            {:error,
             "output #{output.name}: its :from, #{inspect(from)}, is no output of the camera"}
    end)
  end

  # In the order of their indices, so a source has its size before the outputs made from it.
  defp inherit_resolutions(described, indices) do
    sized =
      described
      |> Enum.sort_by(&Map.fetch!(indices, &1.name))
      |> Enum.reduce(%{}, fn
        %{width: nil, from: from} = output, sized ->
          %{width: width, height: height} = Map.fetch!(sized, from)
          Map.put(sized, output.name, %{output | width: width, height: height})

        output, sized ->
          Map.put(sized, output.name, output)
      end)

    Enum.map(described, &Map.fetch!(sized, &1.name))
  end

  defp check_sources(described) do
    by_name = Map.new(described, &{&1.name, &1})

    Enum.find_value(described, :ok, fn
      %{from: nil} ->
        nil

      %{from: from} = output ->
        case Map.fetch!(by_name, from) do
          %{format: :jpeg} ->
            {:error,
             "output #{output.name}: its :from, #{inspect(from)}, is a JPEG, " <>
               "which no output is made from"}

          source ->
            with :ok <- whole_fraction(output, source), do: nil
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
