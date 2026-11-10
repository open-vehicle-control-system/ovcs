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

  Both backends run nx_stereo's segments (`NxStereo.Segment`) on a
  `Pair`: a pair's camera frames are decoded into the segment's entries
  (`entries/2`), and each member's `finish/3` fills the pair from the
  outputs (`finish_members/3`).

  A pair goes through a segment in three steps: `c:send_request/2`
  takes the pair's inputs (`entries/2`) and hands them to the
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
  @type entry_spec :: NxStereo.Segment.entry_spec()

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
  defdelegate entry_fields(members), to: NxStereo.Segment

  @doc """
  Each of the `entry_fields/1` of `members` with the shape and type it
  enters a segment with in `context`; see `NxStereo.Segment.entry_specs/3`.
  """
  @spec entry_specs([map()], Stage.context(), keyword()) ::
          {:ok, [{atom(), entry_spec()}]} | {:error, String.t()}
  defdelegate entry_specs(members, context, opts \\ []), to: NxStereo.Segment

  @doc "The camera frames among the entry fields, which a segment reads and returns nothing of."
  @spec frame_fields() :: [atom()]
  defdelegate frame_fields, to: NxStereo.Segment

  @doc """
  The fields of `pair` that `specs`, from `entry_specs/3`, name, as a
  segment's entries: each camera frame decoded to a tensor, every other
  field as it is; or why a frame does not decode: a grey frame whose
  bytes do not fill its size (`{:frame_bytes, field, bytes, expected}`),
  or a frame the decoder refuses.
  """
  @spec entries(Pair.t(), [{atom(), entry_spec()}]) ::
          {:ok, [{atom(), term()}]} | {:error, term()}
  def entries(%Pair{} = pair, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn {field, _spec}, {:ok, entries} ->
      case field_value(pair, field) do
        {:ok, value} -> {:cont, {:ok, entries ++ [{field, value}]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp field_value(pair, field) when field in @frames do
    case Map.fetch!(pair, field) do
      %Frame{grey: grey, width: width, height: height}
      when is_binary(grey) and byte_size(grey) != width * height ->
        {:error, {:frame_bytes, field, byte_size(grey), width * height}}

      frame ->
        Frame.to_tensor(frame)
    end
  end

  defp field_value(pair, field), do: {:ok, Map.fetch!(pair, field)}

  @doc """
  A segment's `outputs` with `pair`'s entry fields but the frames, which the
  stages read as they were given unless they replaced them.
  """
  @spec with_entries(Pair.t(), [{atom(), term()}], map()) :: map()
  def with_entries(%Pair{} = pair, specs, outputs) do
    entry = Keyword.keys(specs) -- frame_fields()
    pair |> Map.take(entry) |> Map.merge(outputs)
  end

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
