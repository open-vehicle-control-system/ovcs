defmodule VisionCore.Stereo.Segment do
  @moduledoc """
  A run of consecutive `VisionCore.Stereo.NxStage`s that
  `VisionCore.Stereo.Pipeline` runs on a device as one stage:
  `VisionCore.Stereo.NxSegment` compiles them, and
  `VisionCore.Stereo.NativeSegment` computes them in the `stereo_match`
  Port. A segment's state holds its `:members`, initialised pipeline
  stages (`%{module:, name:, state:}`).

  A segment later in the stages runs with `c:run/2`. The first one runs
  in two halves: `c:send_request/2` hands a pair to the device without
  waiting, `c:response/3` recognises its outputs among the pipeline's
  messages, and `c:collect/3` fills the pair from them.
  """

  alias VisionCore.Stereo.{Pair, Stage}

  @type t :: %{required(:members) => [map()], optional(atom()) => term()}

  @doc "Runs the segment on `pair`, in the shape of `c:VisionCore.Stereo.Stage.run/2`."
  @callback run(Pair.t(), t()) :: {:ok, Pair.t(), t()} | {:error, term(), t()}

  @doc """
  Hands `pair` to the device without waiting, returning the request
  that `c:response/3` recognises its outputs by. Pairs are computed in
  the order sent.
  """
  @callback send_request(Pair.t(), t()) :: {:ok, request :: term()} | {:error, term()}

  @doc """
  When `message` is the reply to `request`, sent with `segment`: the
  pair's outputs, the segment to keep, which carries the values its
  stages pass to the next pair, and the monotonic time in nanoseconds
  the device was done; `:no_reply` for another message.
  """
  @callback response(message :: term(), request :: term(), segment :: t()) ::
              {:ok, outputs :: map(), t(), done_ns :: integer()} | {:error, term()} | :no_reply

  @doc "Fills `pair` from the outputs `c:response/3` returned with `segment`."
  @callback collect(Pair.t(), outputs :: map(), segment :: t()) :: Pair.t()

  @doc """
  How many pairs the pipeline keeps at the device at once: with one, a
  pair is collected while the next one's device work runs.
  """
  @callback depth() :: pos_integer()

  @doc "Each member's name and time on the device for the last pair, in nanoseconds, when the device reports them."
  @callback member_times(t()) :: [{atom(), non_neg_integer()}]

  @doc "Where the segment runs, and with what."
  @callback compute(t()) :: VisionCore.Parameters.Group.compute()

  @doc "The segment with `members` re-initialised for a new `context` of the same size."
  @callback reload(t(), members :: [map()], Stage.context()) :: t()

  @doc "The segment with the member at `index` in a new `state`, from the next pair on."
  @callback put_member_state(t(), index :: non_neg_integer(), state :: term()) :: t()
end
