defmodule VisionCore.Stereo.Segment do
  @moduledoc """
  A backend that runs consecutive `VisionCore.Stereo.NxStage`s on a
  device as one `VisionCore.Stereo.Pipeline` stage:
  `VisionCore.Stereo.NxSegment` compiles them, and
  `VisionCore.Stereo.NativeSegment` computes them in the `stereo_match`
  Port. The pipeline's `:backends` lists the backends in order; each Nx
  stage goes to the first whose `c:accepts?/3` takes it, and each run of
  consecutive stages one backend takes becomes one segment, from
  `c:build/3`. A segment's state holds its `:members`, initialised
  pipeline stages (`%{module:, name:, state:}`).

  A pair goes through a segment in three steps: `c:send_request/2`
  takes the pair's inputs (`entry_tensors/2`) and hands them to the
  device without waiting, the device's reply comes back as a message,
  and `c:collect/4` downloads what the device left there and fills the
  pair. The first segment's reply is one of the pipeline's messages,
  which `c:response/3` recognises, so the pipeline keeps up to
  `c:depth/0` pairs at its device; a later segment runs the three steps
  at once, through `run/4`.

  Each wait on the device, for the reply and for the download, lasts at
  most the pipeline's `:device_timeout_ms`: past it, the pipeline stops.
  A pair `c:send_request/2` refuses, such as one with frames of another
  size, never reaches the device. A reply or a download that is an
  error, such as an exception on the device, fails that pair on the
  device. Either way only that pair is dropped, but a run of pairs the
  device fails stops the pipeline. A reply `{:stop, reason}`, from a
  device that refuses the segment itself, such as its configuration,
  stops the pipeline at once.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Pair, Stage}

  @frames [:left_frame, :right_frame]
  @images [:left, :right]
  @maps [:disparity]

  @type t :: %{required(:members) => [map()], optional(atom()) => term()}

  @typedoc """
  What a segment returns for a pair: its outputs, the segment to keep,
  and when the device was done; the error the device failed it with; or
  why the device refuses the segment itself.
  """
  @type response ::
          {:ok, outputs :: map(), t(), done_ns :: integer()}
          | {:error, term()}
          | {:stop, term()}

  @typedoc "The shape and type a `Pair` field enters a segment with."
  @type entry_spec :: {tuple(), Nx.Type.t()}

  @doc """
  The segment of `members`, initialised pipeline stages that
  `c:accepts?/3` took, for `context`, with the options the pipeline's
  `:backends` gives this backend; or why it cannot start.
  """
  @callback build(members :: [map()], Stage.context(), opts :: keyword()) ::
              {:ok, t()} | {:error, String.t()}

  @doc """
  Whether the backend runs the Nx stage `module`, initialised to
  `stage_state`, computing as `compute` says: compiled with Nx (`:nx`),
  or natively (`:native`). The pipeline asks with the stage's `compute:`
  option, else its own `c:VisionCore.Stereo.NxStage.compute/1`, else
  its `:compute`, and under its `:native` asks again with `:nx` when no
  backend takes the stage natively.
  """
  @callback accepts?(module(), stage_state :: term(), compute :: :nx | :native) :: boolean()

  @doc """
  Hands `pair` to the device without waiting, returning the request
  that `c:response/3` and `c:await/3` recognise its reply by; or why the
  device cannot take it, before it reaches the device. Pairs are
  computed in the order sent.
  """
  @callback send_request(Pair.t(), t()) :: {:ok, request :: term()} | {:error, term()}

  @doc """
  When `message` is the reply to `request`, sent with `segment`: the
  pair's outputs, the segment to keep, which carries the values its
  stages pass to the next pair, and the monotonic time in nanoseconds
  the device was done; `{:error, reason}` when the device failed the
  pair, `{:stop, reason}` when it refuses the segment itself; `:no_reply`
  for another message.
  """
  @callback response(message :: term(), request :: term(), segment :: t()) ::
              response() | :no_reply

  @doc """
  Waits up to `timeout` milliseconds for the reply to `request`, sent
  with `segment`, without taking other messages: what `c:response/3`
  returns for it, or `:timeout`.
  """
  @callback await(request :: term(), segment :: t(), timeout()) :: response() | :timeout

  @doc """
  `pair` filled from the outputs its reply returned with `segment`,
  downloading those still on the device within `timeout` milliseconds;
  the download's error, or `:timeout`.
  """
  @callback collect(Pair.t(), outputs :: map(), segment :: t(), timeout()) ::
              {:ok, Pair.t()} | {:error, term()} | :timeout

  @doc """
  How many pairs the pipeline keeps at the device at once: with one, a
  pair is collected while the next one's device work runs.
  """
  @callback depth() :: pos_integer()

  @doc """
  The segment for the next pair, from `current`, the segment in force,
  and `replied`, the one a pair came back with. The pipeline calls it on
  every reply of its first segment. `current` is usually the segment the
  pair was sent with, and the result must then carry `replied`'s values
  unchanged. A live setting changed while the pair was at the device
  makes `current` another segment, whose inputs the result keeps, with
  `replied`'s carried values; a reload since then makes it one whose
  carried values started over, which the result keeps.
  """
  @callback merge_carry(current :: t(), replied :: t()) :: t()

  @doc "Each member's name and time on the device for the last pair, in nanoseconds, when the device reports them."
  @callback member_times(t()) :: [{atom(), non_neg_integer()}]

  @doc "Where the segment runs, and with what."
  @callback compute(t()) :: VisionCore.Parameters.Group.compute()

  @doc "The segment with `members` re-initialised for a new `context` of the same size."
  @callback reload(t(), members :: [map()], Stage.context()) :: t()

  @doc "The segment with the member at `index` in a new `state`, from the next pair on."
  @callback put_member_state(t(), index :: non_neg_integer(), state :: term()) :: t()

  @doc """
  Runs `pair` through `segment`, of the backend `module`, waiting up to
  `timeout` milliseconds for each of its reply and its download: the
  pair filled and the segment to keep; `{:refused, reason}` when
  `c:send_request/2` refused the pair, `{:error, reason}` when the
  device failed it, `{:stop, reason}` when the device refuses the
  segment, or `:timeout`.
  """
  @spec run(module(), Pair.t(), t(), timeout()) ::
          {:ok, Pair.t(), t()}
          | {:refused, term()}
          | {:error, term()}
          | {:stop, term()}
          | :timeout
  def run(module, %Pair{} = pair, segment, timeout) do
    case module.send_request(pair, segment) do
      {:ok, request} ->
        with {:ok, outputs, segment, _done_ns} <- module.await(request, segment, timeout),
             {:ok, pair} <- module.collect(pair, outputs, segment, timeout),
             do: {:ok, pair, segment}

      {:error, reason} ->
        {:refused, reason}
    end
  end

  @doc "The `Pair` fields `members` read that no member before the reader provides."
  @spec entry_fields([map()]) :: [atom()]
  def entry_fields(members) do
    {entry, _provided} =
      Enum.reduce(members, {[], MapSet.new()}, fn member, {entry, provided} ->
        needed =
          Enum.reject(member.module.requires(), &(MapSet.member?(provided, &1) or &1 in entry))

        {entry ++ needed, MapSet.union(provided, MapSet.new(member.module.provides()))}
      end)

    entry
  end

  @doc """
  Each of the `entry_fields/1` of `members` with the shape and type it
  enters a segment with in `context`: the camera frames (`:left_frame`,
  `:right_frame`) as `u8` at the frame size, the rectified images
  (`:left`, `:right`) as `u8` and `:disparity` as `f32` at the working
  size. Another field, which only a CPU stage fills, cannot enter one.
  """
  @spec entry_specs([map()], Stage.context()) ::
          {:ok, [{atom(), entry_spec()}]} | {:error, String.t()}
  def entry_specs(members, context) do
    members
    |> entry_fields()
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, specs} ->
      case entry_spec(field, context) do
        {:ok, spec} -> {:cont, {:ok, specs ++ [{field, spec}]}}
        :error -> {:halt, {:error, "a segment cannot read #{inspect(field)} from a CPU stage"}}
      end
    end)
  end

  defp entry_spec(field, context) when field in @frames,
    do: {:ok, {{context.frame_height, context.frame_width}, {:u, 8}}}

  defp entry_spec(field, context) when field in @images,
    do: {:ok, {{context.height, context.width}, {:u, 8}}}

  defp entry_spec(field, context) when field in @maps,
    do: {:ok, {{context.height, context.width}, {:f, 32}}}

  defp entry_spec(_field, _context), do: :error

  @doc "The camera frames among the entry fields, which a segment reads and returns nothing of."
  @spec frame_fields() :: [atom()]
  def frame_fields, do: @frames

  @doc """
  The fields of `pair` that `specs`, from `entry_specs/2`, name, each a
  tensor of its shape and type, a camera frame decoded; or why not: a
  field of another size (`{:frame_size, field, shape, expected}`), a
  grey frame whose bytes do not fill its size (`{:frame_bytes, field,
  bytes, expected}`), a frame that does not decode, or a field that
  holds no tensor.
  """
  @spec entry_tensors(Pair.t(), [{atom(), entry_spec()}]) ::
          {:ok, [{atom(), Nx.Tensor.t()}]} | {:error, term()}
  def entry_tensors(%Pair{} = pair, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn {field, {expected, type}}, {:ok, tensors} ->
      with {:ok, tensor} <- field_tensor(pair, field),
           :ok <- check_shape(field, Nx.shape(tensor), expected) do
        {:cont, {:ok, tensors ++ [{field, Nx.as_type(tensor, type)}]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp field_tensor(pair, field) when field in @frames do
    case Map.fetch!(pair, field) do
      %Frame{grey: grey, width: width, height: height}
      when is_binary(grey) and byte_size(grey) != width * height ->
        {:error, {:frame_bytes, field, byte_size(grey), width * height}}

      frame ->
        Frame.to_tensor(frame)
    end
  end

  defp field_tensor(pair, field) do
    case Map.fetch!(pair, field) do
      %Nx.Tensor{} = tensor -> {:ok, tensor}
      other -> {:error, {:not_a_tensor, field, other}}
    end
  end

  defp check_shape(_field, shape, shape), do: :ok

  defp check_shape(field, shape, expected),
    do: {:error, {:frame_size, field, shape, expected}}

  @doc """
  `pair` filled from a segment's `outputs` by each member's
  `c:VisionCore.Stereo.NxStage.finish/3`, or with each output named like
  a field the member provides.
  """
  @spec finish_members([map()], Pair.t(), map()) :: Pair.t()
  def finish_members(members, pair, outputs),
    do: Enum.reduce(members, pair, &finish(&1, &2, outputs))

  defp finish(member, pair, outputs) do
    if function_exported?(member.module, :finish, 3) do
      member.module.finish(pair, outputs, member.state)
    else
      member.module.provides()
      |> Enum.filter(&Map.has_key?(outputs, &1))
      |> Enum.reduce(pair, &Map.put(&2, &1, Map.fetch!(outputs, &1)))
    end
  end
end
