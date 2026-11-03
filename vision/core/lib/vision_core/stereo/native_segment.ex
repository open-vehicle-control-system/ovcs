defmodule VisionCore.Stereo.NativeSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s computed natively, in
  the `stereo_match` Port through `VisionCore.Stereo.Matcher`, and run on
  each pair as one stage: the counterpart of `VisionCore.Stereo.NxSegment`
  for a CPU, where the compiled Nx is many times slower, as on a
  Raspberry Pi 5.

  Each stage it `accepts?/3` has a native implementation with the
  results of its Nx step: integer outputs and the `f32` values it
  computes in the same order are identical, and the sums the measuring
  stages reduce on the device agree to the rounding of their order. The
  Port keeps what the stages carry from one pair to the next and what
  depends only on their settings, such as the rectification maps.

  The Port is configured with each stage's kind
  (`c:VisionCore.Stereo.NxStage.native_kind/0`), its build settings and
  the constants its step shares with the Port
  (`c:VisionCore.Stereo.NxStage.native_constants/0`). A pair is then one
  request: the fields the run needs from earlier stages and each stage's
  `params/2`, so a live setting applies from the next pair sent. The
  reply holds the tensors the Nx steps would have produced, as
  `Nx.BinaryBackend` tensors, and each stage's `finish/3` fills the
  `Pair` from them as after an Nx segment. A calibration reload
  (`reload/3`) configures the stages again, which starts what they carry
  over, as `VisionCore.Stereo.NxSegment.reload/3` does.

  Building a segment does not reach the Port: it is configured on its
  first pair, so `mix vision_core.nx_cache` starts a pipeline with native
  segments without one. A configuration the Port refuses, such as a kind
  it has no implementation of, a setting a stage does not take or frames
  smaller than the working size to rectify, answers that pair with
  `{:stop, reason}`: the segment cannot run. The process that builds it
  owns it: the Port releases it once that process exits.

  `send_request/2` sends a pair without waiting for its outputs, which
  `response/3` recognises among the process's messages, or `await/3`
  waits for, so a process can have several pairs at the Port: they are
  computed in the order sent.
  """

  @behaviour VisionCore.Stereo.Segment

  alias VisionCore.Stereo.{Matcher, NxStage, Pair, Segment, Stage}

  @enforce_keys [:matcher, :id, :version, :members, :specs, :configuration, :inputs, :context]
  defstruct [
    :matcher,
    :owner,
    :id,
    :version,
    :members,
    :specs,
    :configuration,
    :inputs,
    :context,
    times_us: []
  ]

  @type t :: %__MODULE__{}

  @configure 1
  @run 2
  @types %{0 => {:u, 8}, 1 => {:u, 16}, 2 => {:f, 32}, 3 => {:s, 32}}
  @type_codes %{{:u, 8} => 0, {:f, 32} => 2}

  @doc "Where a native segment runs: the `stereo_match` Port, on the CPU."
  @impl VisionCore.Stereo.Segment
  @spec compute(t()) :: VisionCore.Parameters.Group.compute()
  def compute(%__MODULE__{}), do: %{runs_on: :cpu, implementation: :rust, backend: nil}

  @doc """
  Two pairs: the Port reads one and writes the other's outputs while it
  computes, and carries its stages' values from one pair to the next.
  """
  @impl VisionCore.Stereo.Segment
  @spec depth() :: pos_integer()
  def depth, do: 2

  @doc """
  Whether `module` declares the kind of its native implementation
  (`c:VisionCore.Stereo.NxStage.native_kind/0`), for a stage to compute
  natively.
  """
  @impl VisionCore.Stereo.Segment
  @spec accepts?(module(), term(), :nx | :native) :: boolean()
  def accepts?(module, _state, compute),
    do: compute == :native and NxStage.native_kind(module) != nil

  @doc """
  The segment of `members`, initialised pipeline stages (`%{module:,
  name:, state:}`) that it `accepts?/3`, for `context`, with `opts`:
  `:matcher` (`VisionCore.Stereo.Matcher`), the `VisionCore.Stereo.Matcher`
  server its pairs go to.
  """
  @impl VisionCore.Stereo.Segment
  @spec build([map()], Stage.context(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context, opts) do
    case Keyword.validate(opts, matcher: Matcher) do
      {:ok, opts} -> new_segment(members, context, opts[:matcher])
      {:error, unknown} -> {:error, "unknown build options #{inspect(unknown)}"}
    end
  end

  defp new_segment(members, context, matcher) do
    with {:ok, specs} <- Segment.entry_specs(members, context) do
      segment = %__MODULE__{
        matcher: matcher,
        owner: self(),
        id: rem(System.unique_integer([:positive]), 0x1_0000_0000),
        version: 0,
        members: members,
        specs: specs,
        configuration: nil,
        inputs: nil,
        context: context
      }

      {:ok, configure(segment)}
    end
  end

  @doc """
  The segment with `members` re-initialised for a new `context` of the
  same size: configured again from its next pair on, carrying nothing
  over.
  """
  @impl VisionCore.Stereo.Segment
  @spec reload(t(), [map()], Stage.context()) :: t()
  def reload(%__MODULE__{} = segment, members, context),
    do: configure(%{segment | members: members, context: context, version: segment.version + 1})

  @doc "The segment with the member at `index` in a new `state`, from the next pair on."
  @impl VisionCore.Stereo.Segment
  @spec put_member_state(t(), non_neg_integer(), term()) :: t()
  def put_member_state(%__MODULE__{members: members} = segment, index, state) do
    members = List.update_at(members, index, &%{&1 | state: state})
    %{segment | members: members, inputs: inputs(members, segment.context)}
  end

  @doc "`current`: the Port keeps what the stages carry."
  @impl VisionCore.Stereo.Segment
  @spec merge_carry(t(), t()) :: t()
  def merge_carry(%__MODULE__{} = current, %__MODULE__{}), do: current

  @doc """
  Takes `pair`'s inputs and sends them to the Port without waiting:
  returns the request's id, which `response/3` and `await/3` recognise
  its reply by; or why the inputs do not fit. Pairs a process sends are
  computed in that order, which the stages that carry values from one
  pair to the next rely on.
  """
  @impl VisionCore.Stereo.Segment
  @spec send_request(Pair.t(), t()) :: {:ok, :gen_server.request_id()} | {:error, term()}
  def send_request(%Pair{} = pair, %__MODULE__{} = segment) do
    with {:ok, entry} <- Segment.entry_tensors(pair, segment.specs) do
      request = [<<@run, segment.id::little-32>>, segment.inputs, encode_entries(entry)]

      {:ok,
       Matcher.send_run(
         segment.matcher,
         segment.owner,
         segment.id,
         segment.version,
         segment.configuration,
         request
       )}
    end
  end

  @doc """
  The Port's outputs for the pair sent as `request_id`, from `segment`
  (the one it was sent with), whose `:times_us` holds each member's
  time in the Port, in microseconds, with the monotonic time the reply
  is received at, when `message` is its reply; `:no_reply` when it is
  another message.
  """
  @impl VisionCore.Stereo.Segment
  @spec response(term(), :gen_server.request_id(), t()) :: Segment.response() | :no_reply
  def response(message, request_id, %__MODULE__{} = segment) do
    case :gen_server.check_response(message, request_id) do
      :no_reply -> :no_reply
      response -> received(response, segment)
    end
  end

  @doc """
  What `response/3` returns for the pair sent as `request_id`, waiting
  for its reply up to `timeout` ms, or `:timeout`.
  """
  @impl VisionCore.Stereo.Segment
  @spec await(:gen_server.request_id(), t(), timeout()) :: Segment.response() | :timeout
  def await(request_id, %__MODULE__{} = segment, timeout) do
    case :gen_server.receive_response(request_id, timeout) do
      :timeout -> :timeout
      response -> received(response, segment)
    end
  end

  defp received({:reply, {:error, {:configuration_refused, reason}}}, _segment),
    do: {:stop, reason}

  defp received({:reply, reply}, segment) do
    with {:ok, outputs, segment} <- run_outputs(reply, segment),
         do: {:ok, outputs, segment, System.monotonic_time(:nanosecond)}
  end

  defp received({:error, {reason, _matcher}}, _segment), do: {:error, {:matcher_down, reason}}

  @doc "Each member's name and time in the Port for the pair `segment` was returned with, in nanoseconds."
  @impl VisionCore.Stereo.Segment
  @spec member_times(t()) :: [{atom(), non_neg_integer()}]
  def member_times(%__MODULE__{members: members, times_us: times_us}),
    do: Enum.zip_with(members, times_us, &{&1.name, &2 * 1_000})

  defp run_outputs({:ok, reply}, segment) do
    with {:ok, times_us, outputs} <- decode(reply),
         do: {:ok, outputs, %{segment | times_us: times_us}}
  end

  defp run_outputs({:error, _reason} = error, _segment), do: error

  @doc "Fills `pair` from `outputs`, which the reply brought back: there is nothing to download."
  @impl VisionCore.Stereo.Segment
  @spec collect(Pair.t(), map(), t(), timeout()) :: {:ok, Pair.t()}
  def collect(%Pair{} = pair, outputs, %__MODULE__{} = segment, _timeout) do
    # Entry tensors pass through, as an Nx segment returns them.
    entry = Keyword.keys(segment.specs) -- Segment.frame_fields()
    outputs = pair |> Map.take(entry) |> Map.merge(outputs)
    {:ok, Segment.finish_members(segment.members, pair, outputs)}
  end

  defp configure(segment) do
    %{
      segment
      | configuration: configuration(segment),
        inputs: inputs(segment.members, segment.context)
    }
  end

  defp configuration(%__MODULE__{id: id, members: members, context: context}) do
    [
      <<@configure, id::little-32, context.width::little-16, context.height::little-16,
        context.frame_width::little-16, context.frame_height::little-16, length(members)>>,
      Enum.map(members, fn member ->
        settings = build_settings(member)

        [
          length_prefixed(member.module.native_kind()),
          length(settings),
          Enum.map(settings, fn {key, value} ->
            [length_prefixed(key), <<value::little-float-64>>]
          end)
        ]
      end)
    ]
    |> IO.iodata_to_binary()
  end

  # The stage's build settings and native constants; its live settings go with each pair.
  defp build_settings(member) do
    values =
      if function_exported?(member.module, :options, 1),
        do: member.module.options(member.state),
        else: %{}

    build =
      for {key, spec} <- option_specs(member.module),
          Map.get(spec, :applies, :live) == :build,
          is_number(values[key]) or is_boolean(values[key]),
          do: {key, setting_float(values[key])}

    constants =
      for {key, value} <- member.module |> NxStage.native_constants() |> Enum.sort(),
          do: {key, setting_float(value)}

    build ++ constants
  end

  defp option_specs(module) do
    if function_exported?(module, :option_specs, 0), do: module.option_specs(), else: []
  end

  defp setting_float(true), do: 1.0
  defp setting_float(false), do: 0.0
  defp setting_float(value), do: value * 1.0

  # Each member's params, as the f32 values a compiled segment takes.
  defp inputs(members, context) do
    [
      length(members),
      Enum.map(members, fn member ->
        values =
          member.module |> NxStage.params(member.state, context) |> flatten("") |> Enum.sort()

        [
          length(values),
          Enum.map(values, fn {key, binary} ->
            [length_prefixed(key), <<div(byte_size(binary), 4)::little-16>>, binary]
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

  defp length_prefixed(key) do
    key = to_string(key)
    [byte_size(key), key]
  end

  defp encode_entries(entry) do
    [
      length(entry),
      Enum.map(entry, fn {field, tensor} ->
        {height, width} = Nx.shape(tensor)

        [
          length_prefixed(field),
          <<Map.fetch!(@type_codes, Nx.type(tensor)), 2, height::little-32, width::little-32>>,
          Nx.to_binary(tensor)
        ]
      end)
    ]
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
