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
        full: [resolution: {2028, 1520}, processor: :cpu, send: false],
        full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30],
        half: [resolution: {1014, 760}, from: :full],
        half_jpeg: [from: :half, format: :jpeg, quality: 80]
      ]

  An output's `:format` is `:rgb`, frames of 8-bit red, green and blue
  pixels, by default, or, for an output made `:from` another, `:jpeg`:
  that output's image encoded by the driver, once a frame, at
  `:quality` 1 to 100 (80); or `:h264`: that output's images encoded as
  an H.264 stream on the board's video encoder, at `:bitrate_kbps`, 1 to
  2000000 kilobits a second, with a key frame every
  `:keyframe_interval` frames, both required, at an even width and
  height. An output made `:from` another has that output's
  `:resolution` unless it is given one. No output is made from a JPEG
  or an H.264 output.

  An H.264 output is a video, not an image (`videos/1`, `images/1`):
  each of its frames (`VisionCore.Camera.Frame`) carries one frame of
  the stream, which a decoder needs every frame since the last key
  frame to show, so only a consumer of videos takes it.

  An output with `send: false` is made at every frame, for the outputs
  made `:from` it, but its frames are not sent to the vision core: no
  consumer takes it (`sent/1`). Only an output another is made from
  can be left unsent.

  The first sent image output in the configuration is the camera's default,
  the one a consumer that names no output takes
  (`VisionCore.Camera.Unit`). `:index` is the output's place among those
  the driver makes, sent or not: an output scaled from another comes
  after it.
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
    quality: nil,
    bitrate_kbps: nil,
    keyframe_interval: nil,
    send: true
  ]

  @type t :: %__MODULE__{
          name: atom(),
          index: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          processor: atom() | nil,
          from: atom() | nil,
          format: :rgb | :jpeg | :h264,
          quality: 1..100 | nil,
          bitrate_kbps: pos_integer() | nil,
          keyframe_interval: pos_integer() | nil,
          send: boolean()
        }

  @typedoc "Each processor a driver has, with the resolutions it can make."
  @type processors :: %{atom() => [{pos_integer(), pos_integer()}]}

  @options [
    :resolution,
    :processor,
    :from,
    :format,
    :quality,
    :bitrate_kbps,
    :keyframe_interval,
    :send
  ]
  @formats [:rgb, :jpeg, :h264]
  @default_quality 80
  @h264_options [:bitrate_kbps, :keyframe_interval]
  # The encoder takes its bitrate in bits a second and its interval as signed 32-bit integers.
  @max_bitrate_kbps 2_000_000
  @max_keyframe_interval 2_147_483_647

  @doc """
  The outputs `outputs` describes, in its order, for a driver with
  `processors` that sends the `:formats` of `options` (`[:rgb]`);
  `{:error, message}` for one that cannot be made: none, a name given
  twice, an option it does not take, a missing or malformed
  `:resolution`, neither or both of `:processor` and `:from`, a
  processor the driver lacks or a resolution it cannot make, a format
  it does not send, a JPEG or an H.264 stream made by a processor, a
  `:quality` outside 1 to 100 or without `format: :jpeg`, a
  `:bitrate_kbps` or `:keyframe_interval` missing, out of range or
  without `format: :h264`, a `:send` other than a boolean, a `:from`
  naming no output, a JPEG or an H.264 stream, outputs whose `:from`
  runs in a cycle, a size that is not a whole fraction of its source's,
  an H.264 stream of an odd width or height, or an output with
  `send: false` that no output is made from.
  """
  @spec resolve(term(), processors(), [{:formats, [:rgb | :jpeg | :h264]}]) ::
          {:ok, [t()]} | {:error, String.t()}
  def resolve(outputs, processors, options \\ []) do
    formats = Keyword.get(options, :formats, [:rgb])

    with :ok <- check_list(outputs),
         {:ok, described} <- describe_each(outputs, processors, formats),
         :ok <- check_sources_named(described),
         {:ok, indices} <- indices(described),
         sized = inherit_resolutions(described, indices),
         :ok <- check_sources(sized),
         :ok <- check_even_videos(sized),
         :ok <- check_unsent_sources(sized),
         do: {:ok, Enum.map(sized, &%{&1 | index: Map.fetch!(indices, &1.name)})}
  end

  @doc "The outputs of `outputs` sent to the vision core, in their order."
  @spec sent([t()]) :: [t()]
  def sent(outputs), do: Enum.filter(outputs, & &1.send)

  @doc "The image outputs of `outputs` sent to the vision core, in their order: all but the videos."
  @spec images([t()]) :: [t()]
  def images(outputs), do: outputs |> sent() |> Enum.reject(&video?/1)

  @doc "The H.264 outputs of `outputs`, in their order."
  @spec videos([t()]) :: [t()]
  def videos(outputs), do: Enum.filter(outputs, &video?/1)

  @doc "Whether `output` is an H.264 stream, whose frames carry no image."
  @spec video?(t()) :: boolean()
  def video?(%__MODULE__{format: format}), do: format == :h264

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
         {:ok, encoding} <- format(options, maker, formats),
         {:ok, send} <- send_option(Keyword.get(options, :send, true)),
         :ok <- check_processor(maker, {width, height}, processors) do
      {:ok,
       %__MODULE__{
         name: name,
         index: nil,
         width: width,
         height: height,
         processor: maker[:processor],
         from: maker[:from],
         format: encoding.format,
         quality: encoding[:quality],
         bitrate_kbps: encoding[:bitrate_kbps],
         keyframe_interval: encoding[:keyframe_interval],
         send: send
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
    misplaced_h264_option = Enum.find(@h264_options, &Keyword.has_key?(options, &1))

    cond do
      format not in @formats ->
        {:error, "its :format is :rgb, :jpeg or :h264, got #{inspect(format)}"}

      format not in formats ->
        {:error,
         "its format #{inspect(format)} is not one this driver makes " <>
           "(#{Enum.map_join(formats, ", ", &inspect/1)})"}

      format != :jpeg and Keyword.has_key?(options, :quality) ->
        {:error, "its :quality is a JPEG's: give it format: :jpeg"}

      format != :h264 and misplaced_h264_option != nil ->
        {:error, "its #{inspect(misplaced_h264_option)} is an H.264's: give it format: :h264"}

      format == :rgb ->
        {:ok, %{format: :rgb}}

      Keyword.has_key?(maker, :processor) ->
        {:error, "#{encoded_name(format)} is made :from another output, not by a :processor"}

      format == :jpeg ->
        jpeg_quality(Keyword.get(options, :quality, @default_quality))

      true ->
        h264_encoding(options[:bitrate_kbps], options[:keyframe_interval])
    end
  end

  defp encoded_name(:jpeg), do: "a JPEG"
  defp encoded_name(:h264), do: "an H.264 stream"

  defp jpeg_quality(quality) when is_integer(quality) and quality in 1..100,
    do: {:ok, %{format: :jpeg, quality: quality}}

  defp jpeg_quality(other),
    do: {:error, "its :quality is an integer from 1 to 100, got #{inspect(other)}"}

  defp h264_encoding(bitrate_kbps, keyframe_interval) do
    cond do
      not (is_integer(bitrate_kbps) and bitrate_kbps in 1..@max_bitrate_kbps) ->
        {:error,
         "its :bitrate_kbps is an integer from 1 to #{@max_bitrate_kbps}, " <>
           "got #{inspect(bitrate_kbps)}"}

      not (is_integer(keyframe_interval) and keyframe_interval in 1..@max_keyframe_interval) ->
        {:error,
         "its :keyframe_interval is a whole number of frames from 1, " <>
           "got #{inspect(keyframe_interval)}"}

      true ->
        {:ok, %{format: :h264, bitrate_kbps: bitrate_kbps, keyframe_interval: keyframe_interval}}
    end
  end

  defp send_option(send) when is_boolean(send), do: {:ok, send}
  defp send_option(other), do: {:error, "its :send is true or false, got #{inspect(other)}"}

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
          %{format: format} when format in [:jpeg, :h264] ->
            {:error,
             "output #{output.name}: its :from, #{inspect(from)}, is #{encoded_name(format)}, " <>
               "which no output is made from"}

          source ->
            with :ok <- whole_fraction(output, source), do: nil
        end
    end)
  end

  defp check_even_videos(described) do
    case Enum.find(described, &(video?(&1) and (odd?(&1.width) or odd?(&1.height)))) do
      nil ->
        :ok

      odd ->
        {:error,
         "output #{odd.name}: H.264 takes an even width and height, " <>
           "not #{size({odd.width, odd.height})}"}
    end
  end

  defp odd?(pixels), do: rem(pixels, 2) != 0

  defp check_unsent_sources(described) do
    sources = MapSet.new(described, & &1.from)

    case Enum.find(described, &(not &1.send and &1.name not in sources)) do
      nil ->
        :ok

      unsent ->
        {:error,
         "output #{unsent.name}: it is not sent (send: false), and no output is made from it"}
    end
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
