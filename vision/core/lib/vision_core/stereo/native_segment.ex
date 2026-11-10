defmodule VisionCore.Stereo.NativeSegment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s computed natively, in
  the `stereo_match` Port through `VisionCore.Stereo.Matcher`, and run on
  each pair as one stage: an `NxStereo.NativeSegment` on a `Pair`, the
  counterpart of `VisionCore.Stereo.NxSegment` for a CPU, where the
  compiled Nx is slower, as on a Raspberry Pi 5.

  A pair is one request: the fields the run needs from earlier stages
  and each stage's `params/2`, so a live setting applies from the next
  pair sent. Each stage's `finish/3` fills the `Pair` from the reply's
  tensors as after an Nx segment. Building a segment does not reach the
  Port: it is configured on its first pair, so `mix vision_core.nx_cache`
  starts a pipeline with native segments without one. See
  `NxStereo.NativeSegment` for how the Port computes, refuses a
  configuration and carries values from pair to pair.
  """

  @behaviour VisionCore.Stereo.Segment

  alias VisionCore.Stereo.{Matcher, Pair, Segment, Stage}

  @type t :: NxStereo.NativeSegment.t()

  @doc "Where a native segment runs: the `stereo_match` Port, on the CPU."
  @impl VisionCore.Stereo.Segment
  @spec compute(t()) :: VisionCore.Parameters.Group.compute()
  defdelegate compute(segment), to: NxStereo.NativeSegment

  @doc """
  Two pairs: the Port reads one and writes the other's outputs while it
  computes, and carries its stages' values from one pair to the next.
  """
  @impl VisionCore.Stereo.Segment
  @spec depth() :: pos_integer()
  defdelegate depth, to: NxStereo.NativeSegment

  @doc """
  Whether `module` declares the kind of its native implementation
  (`c:VisionCore.Stereo.NxStage.native_kind/0`), for a stage to compute
  natively.
  """
  @impl VisionCore.Stereo.Segment
  @spec accepts?(module(), term(), :nx | :native) :: boolean()
  defdelegate accepts?(module, state, compute), to: NxStereo.NativeSegment

  @doc """
  The segment of `members`, initialised pipeline stages (`%{module:,
  name:, state:}`) that it `accepts?/3`, for `context`, with `opts`:
  `:matcher` (`VisionCore.Stereo.Matcher`), the `NxStereo.Matcher`
  server its pairs go to.
  """
  @impl VisionCore.Stereo.Segment
  @spec build([map()], Stage.context(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(members, context, opts),
    do: NxStereo.NativeSegment.build(members, context, Keyword.put_new(opts, :matcher, Matcher))

  @doc """
  The segment with `members` re-initialised for a new `context` of the
  same size: configured again from its next pair on, carrying nothing
  over.
  """
  @impl VisionCore.Stereo.Segment
  @spec reload(t(), [map()], Stage.context()) :: t()
  defdelegate reload(segment, members, context), to: NxStereo.NativeSegment

  @doc "The segment with the member at `index` in a new `state`, from the next pair on."
  @impl VisionCore.Stereo.Segment
  @spec put_member_state(t(), non_neg_integer(), term()) :: t()
  defdelegate put_member_state(segment, index, state), to: NxStereo.NativeSegment

  @doc "`current`: the Port keeps what the stages carry."
  @impl VisionCore.Stereo.Segment
  @spec merge_carry(t(), t()) :: t()
  defdelegate merge_carry(current, replied), to: NxStereo.NativeSegment

  @doc """
  Takes `pair`'s inputs and sends them to the Port without waiting:
  returns the request's id, which `response/3` and `await/3` recognise
  its reply by; or why the inputs do not fit. Pairs a process sends are
  computed in that order, which the stages that carry values from one
  pair to the next rely on.
  """
  @impl VisionCore.Stereo.Segment
  @spec send_request(Pair.t(), t()) :: {:ok, :gen_server.request_id()} | {:error, term()}
  def send_request(%Pair{} = pair, %NxStereo.NativeSegment{} = segment) do
    with {:ok, entries} <- Segment.entries(pair, segment.specs),
         do: NxStereo.NativeSegment.send_request(entries, segment)
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
  defdelegate response(message, request_id, segment), to: NxStereo.NativeSegment

  @doc """
  What `response/3` returns for the pair sent as `request_id`, waiting
  for its reply up to `timeout` ms, or `:timeout`.
  """
  @impl VisionCore.Stereo.Segment
  @spec await(:gen_server.request_id(), t(), timeout()) :: Segment.response() | :timeout
  defdelegate await(request_id, segment, timeout), to: NxStereo.NativeSegment

  @doc "Each member's name and time in the Port for the pair `segment` was returned with, in nanoseconds."
  @impl VisionCore.Stereo.Segment
  @spec member_times(t()) :: [{atom(), non_neg_integer()}]
  defdelegate member_times(segment), to: NxStereo.NativeSegment

  @doc "Fills `pair` from `outputs`, which the reply brought back: there is nothing to download."
  @impl VisionCore.Stereo.Segment
  @spec collect(Pair.t(), map(), t(), timeout()) :: {:ok, Pair.t()}
  def collect(%Pair{} = pair, outputs, %NxStereo.NativeSegment{} = segment, _timeout) do
    # Entry fields pass through, as an Nx segment returns them.
    entry = Keyword.keys(segment.specs) -- Segment.frame_fields()
    outputs = pair |> Map.take(entry) |> Map.merge(outputs)
    {:ok, Segment.finish_members(segment.members, pair, outputs)}
  end
end
