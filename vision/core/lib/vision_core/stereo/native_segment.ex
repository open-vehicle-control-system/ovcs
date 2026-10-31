defmodule VisionCore.Stereo.NativeSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s computed natively, in
  the `stereo_match` Port through `VisionCore.Stereo.Matcher`, and run on
  each pair as one stage: the counterpart of `VisionCore.Stereo.NxSegment`
  for a CPU, where the compiled Nx is many times slower, as on a
  Raspberry Pi 5.

  Each stage `supported?/1` has a native implementation with the results
  of its Nx step: integer outputs and the `f32` values it computes in the
  same order are identical, and the sums the measuring stages reduce on
  the device agree to the rounding of their order. The Port keeps what
  the stages carry from one pair to the next and what depends only on
  their settings, such as the rectification maps.

  The Port is configured with each stage's kind and the numbers among
  its `options/1`, its build settings. A pair is then one request: the
  fields the run needs from earlier stages and each stage's `params/2`,
  so a live setting applies from the next pair sent. The reply holds the
  tensors the Nx steps would have produced, as `Nx.BinaryBackend`
  tensors, and each stage's `finish/3` fills the `Pair` from them as
  after an Nx segment. A calibration reload (`reload/3`) configures the
  stages again, which starts what they carry over, as
  `VisionCore.Stereo.NxSegment.reload/3` does.

  Building a segment does not reach the Port: it is configured on its
  first pair, so `mix vision_core.nx_cache` starts a pipeline with native
  segments without one. The process that builds it owns it: the Port
  releases it once that process exits.

  `send_request/2` sends a pair without waiting for its outputs, which
  `response/3` recognises among the process's messages, so a process
  can have several pairs at the Port: they are computed in the order
  sent.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Matcher, NxSegment, Pair, Stage}

  @enforce_keys [:id, :version, :members, :entry, :shapes, :configuration, :inputs, :context]
  defstruct [
    :owner,
    :id,
    :version,
    :members,
    :entry,
    :shapes,
    :configuration,
    :inputs,
    :context,
    times_us: []
  ]

  @type t :: %__MODULE__{}

  @kinds %{
    Stage.Rectification => "rectification",
    Stage.Sharpness => "sharpness",
    Stage.Disparity => "disparity",
    Stage.MedianFilter => "median_filter",
    Stage.SpeckleFilter => "speckle_filter",
    Stage.RowAlignment => "row_alignment",
    Stage.TemporalFilter => "temporal_filter",
    Stage.Depth => "depth",
    Stage.PointCloud => "point_cloud",
    Stage.Quality => "quality"
  }

  @frames [:left_frame, :right_frame]
  @images [:left, :right]
  @maps [:disparity, :depth_m]

  @configure 1
  @run 2
  @types %{0 => {:u, 8}, 1 => {:u, 16}, 2 => {:f, 32}, 3 => {:s, 32}}
  @type_codes %{{:u, 8} => 0, {:f, 32} => 2}

  @doc "Whether `module` has a native implementation."
  @spec supported?(module()) :: boolean()
  def supported?(module), do: Map.has_key?(@kinds, module)

  @doc """
  The segment of `members`, initialised pipeline stages (`%{module:,
  name:, state:}`) that are all `supported?/1`, for `context`.
  """
  @spec build([map()], Stage.context()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context) do
    entry = NxSegment.entry_fields(members)

    case Enum.reject(entry, &(&1 in @frames or &1 in @images or &1 in @maps)) do
      [] ->
        segment = %__MODULE__{
          owner: self(),
          id: rem(System.unique_integer([:positive]), 0x1_0000_0000),
          version: 0,
          members: members,
          entry: entry,
          shapes: Map.new(entry, &{&1, shape(&1, context)}),
          configuration: nil,
          inputs: nil,
          context: context
        }

        {:ok, configure(segment)}

      [field | _] ->
        {:error, "a native stage cannot read #{inspect(field)} from a CPU stage"}
    end
  end

  @doc """
  The segment with `members` re-initialised for a new `context` of the
  same size: configured again from its next pair on, carrying nothing
  over.
  """
  @spec reload(t(), [map()], Stage.context()) :: t()
  def reload(%__MODULE__{} = segment, members, context),
    do: configure(%{segment | members: members, context: context, version: segment.version + 1})

  @doc "The segment with the member at `index` in a new `state`, from the next pair on."
  @spec put_member_state(t(), non_neg_integer(), term()) :: t()
  def put_member_state(%__MODULE__{members: members} = segment, index, state) do
    members = List.update_at(members, index, &%{&1 | state: state})
    %{segment | members: members, inputs: inputs(members, segment.context)}
  end

  @doc """
  Runs the segment on `pair`, in the shape of
  `c:VisionCore.Stereo.Stage.run/2`. The returned segment's `:times_us`
  holds each member's time in the Port, in microseconds.
  """
  @spec run(Pair.t(), t()) :: {:ok, Pair.t(), t()} | {:error, term(), t()}
  def run(%Pair{} = pair, %__MODULE__{} = segment) do
    case dispatch(pair, segment) do
      {:ok, outputs, segment} -> {:ok, collect(pair, outputs, segment), segment}
      {:error, reason} -> {:error, reason, segment}
    end
  end

  @doc """
  The first half of `run/2`: the Port's outputs for `pair`. It changes
  no process state, so it may run in another process while the previous
  pair is collected.
  """
  @spec dispatch(Pair.t(), t()) :: {:ok, map(), t()} | {:error, term()}
  def dispatch(%Pair{} = pair, %__MODULE__{} = segment) do
    with {:ok, request_id} <- send_request(pair, segment) do
      case :gen_server.receive_response(request_id, :infinity) do
        {:reply, reply} -> decoded(reply, segment)
        {:error, {reason, _matcher}} -> {:error, {:matcher_down, reason}}
      end
    end
  end

  @doc """
  `dispatch/2` without waiting: sends `pair` to the Port and returns the
  request's id, which `response/3` recognises its reply by. Pairs a
  process sends are computed in that order, which the stages that carry
  values from one pair to the next rely on.
  """
  @spec send_request(Pair.t(), t()) :: {:ok, :gen_server.request_id()} | {:error, term()}
  def send_request(%Pair{} = pair, %__MODULE__{} = segment) do
    with {:ok, entries} <- entries(pair, segment) do
      request = [<<@run, segment.id::little-32>>, segment.inputs, entries]

      {:ok,
       Matcher.send_run(
         segment.owner,
         segment.id,
         segment.version,
         segment.configuration,
         request
       )}
    end
  end

  @doc """
  What `dispatch/2` returns for the pair sent as `request_id`, from
  `segment` (the one it was sent with), when `message` is its reply;
  `:no_reply` when it is another message.
  """
  @spec response(term(), :gen_server.request_id(), t()) ::
          {:ok, map(), t()} | {:error, term()} | :no_reply
  def response(message, request_id, %__MODULE__{} = segment) do
    case :gen_server.check_response(message, request_id) do
      :no_reply -> :no_reply
      {:reply, reply} -> decoded(reply, segment)
      {:error, {reason, _matcher}} -> {:error, {:matcher_down, reason}}
    end
  end

  defp decoded({:ok, reply}, segment) do
    with {:ok, times_us, outputs} <- decode(reply),
         do: {:ok, outputs, %{segment | times_us: times_us}}
  end

  defp decoded({:error, _reason} = error, _segment), do: error

  @doc "The second half of `run/2`: fills `pair` from `outputs`."
  @spec collect(Pair.t(), map(), t()) :: Pair.t()
  def collect(%Pair{} = pair, outputs, %__MODULE__{} = segment) do
    # Entry tensors pass through, as an Nx segment returns them.
    outputs = pair |> Map.take(segment.entry -- @frames) |> Map.merge(outputs)
    NxSegment.finish_members(segment.members, pair, outputs)
  end

  defp configure(segment) do
    %{
      segment
      | configuration: configuration(segment),
        inputs: inputs(segment.members, segment.context),
        shapes: Map.new(segment.entry, &{&1, shape(&1, segment.context)})
    }
  end

  defp configuration(%__MODULE__{id: id, members: members, context: context}) do
    [
      <<@configure, id::little-32, context.width::little-16, context.height::little-16,
        context.frame_width::little-16, context.frame_height::little-16, length(members)>>,
      Enum.map(members, fn member ->
        settings = build_settings(member)

        [
          name(Map.fetch!(@kinds, member.module)),
          length(settings),
          Enum.map(settings, fn {key, value} -> [name(key), <<value::little-float-64>>] end)
        ]
      end)
    ]
    |> IO.iodata_to_binary()
  end

  defp build_settings(member) do
    if function_exported?(member.module, :options, 1) do
      for {key, value} <- member.module.options(member.state),
          is_number(value) or is_boolean(value) do
        {key, number(value)}
      end
    else
      []
    end
  end

  defp number(true), do: 1.0
  defp number(false), do: 0.0
  defp number(value), do: value * 1.0

  # Each member's params, as the f32 values a compiled segment takes.
  defp inputs(members, context) do
    [
      length(members),
      Enum.map(members, fn member ->
        values = member.module.params(member.state, context) |> flatten("") |> Enum.sort()

        [
          length(values),
          Enum.map(values, fn {key, binary} ->
            [name(key), <<div(byte_size(binary), 4)::little-16>>, binary]
          end)
        ]
      end)
    ]
    |> IO.iodata_to_binary()
  end

  defp flatten(params, prefix) do
    Enum.flat_map(params, fn
      {key, %Nx.Tensor{} = tensor} ->
        [{prefix <> to_string(key), f32_binary(tensor)}]

      {key, value} when is_number(value) ->
        [{prefix <> to_string(key), <<value::little-float-32>>}]

      {key, %{} = nested} ->
        flatten(nested, "#{prefix}#{key}.")
    end)
  end

  defp f32_binary(tensor), do: tensor |> Nx.as_type(:f32) |> Nx.to_binary()

  defp name(key) do
    key = to_string(key)
    [byte_size(key), key]
  end

  defp shape(field, context) when field in @frames,
    do: {context.frame_height, context.frame_width}

  defp shape(_field, context), do: {context.height, context.width}

  defp entries(pair, segment) do
    Enum.reduce_while(segment.entry, {:ok, [length(segment.entry)]}, fn field, {:ok, encoded} ->
      expected = Map.fetch!(segment.shapes, field)

      case entry(pair, field) do
        {:ok, ^expected, type, binary} ->
          {height, width} = expected

          tensor = [
            name(field),
            <<Map.fetch!(@type_codes, type), 2, height::little-32, width::little-32>>,
            binary
          ]

          {:cont, {:ok, [encoded | tensor]}}

        {:ok, shape, _type, _binary} ->
          {:halt, {:error, {:frame_size, field, shape, expected}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp entry(pair, field) when field in @frames do
    case Map.fetch!(pair, field) do
      %Frame{grey: grey, width: width, height: height} when is_binary(grey) ->
        {:ok, {height, width}, {:u, 8}, grey}

      frame ->
        with {:ok, tensor} <- Frame.to_tensor(frame),
             do: {:ok, Nx.shape(tensor), {:u, 8}, Nx.to_binary(tensor)}
    end
  end

  defp entry(pair, field) do
    type = if field in @images, do: {:u, 8}, else: {:f, 32}

    case Map.fetch!(pair, field) do
      %Nx.Tensor{} = tensor ->
        {:ok, Nx.shape(tensor), type, tensor |> Nx.as_type(type) |> Nx.to_binary()}

      other ->
        {:error, {:not_a_tensor, field, other}}
    end
  end

  defp decode(<<count, times::binary-size(count * 4), output_count, outputs::binary>>) do
    times_us = for <<time::little-32 <- times>>, do: time

    with {:ok, outputs} <- decode_outputs(output_count, outputs, %{}),
         do: {:ok, times_us, outputs}
  end

  defp decode(_reply), do: {:error, :bad_reply}

  defp decode_outputs(0, <<>>, outputs), do: {:ok, outputs}

  defp decode_outputs(
         count,
         <<length, key::binary-size(length), type_code, rank, rest::binary>>,
         outputs
       )
       when is_map_key(@types, type_code) and byte_size(rest) >= rank * 4 do
    dimensions_size = rank * 4
    <<dimensions::binary-size(^dimensions_size), rest::binary>> = rest
    shape = for <<dimension::little-32 <- dimensions>>, do: dimension
    {_kind, bits} = type = Map.fetch!(@types, type_code)
    size = Enum.product(shape) * div(bits, 8)

    case rest do
      <<binary::binary-size(^size), rest::binary>> ->
        tensor =
          binary
          |> Nx.from_binary(type, backend: Nx.BinaryBackend)
          |> Nx.reshape(List.to_tuple(shape))

        decode_outputs(count - 1, rest, Map.put(outputs, String.to_existing_atom(key), tensor))

      _short ->
        {:error, :bad_reply}
    end
  end

  defp decode_outputs(_count, _rest, _outputs), do: {:error, :bad_reply}
end
