defmodule VisionCore.Detection.Backend do
  @moduledoc """
  What a detection backend has to do, so `VisionCore.Detection.Pipeline`
  does not care which one it is talking to.

  There are two:

    * `VisionCore.Detection.Backend.Hailo` — a YOLO HEF on a Hailo-8, via a
      Port. The accelerator path, for a vehicle fitted with one.
    * `VisionCore.Detection.Backend.Stub` — fixed boxes, no model. For proving
      the plumbing without an accelerator.

  ## The contract

  `detect/3` is **asynchronous and lossy**. It hands a frame over and
  returns immediately; the boxes arrive later as a message. A frame
  submitted while another is in flight is *dropped*, not queued —
  `{:error, :busy}`. That is deliberate for a live sensor: queueing
  would add latency to a measurement whose only value is being
  current.

  The reply is

      {:inference_detections, sequence, detections}

  where `sequence` is the sequence number the caller passed to `detect/3`,
  and `detections` is `nil` when the backend could not detect on the frame,
  as when its Port went down with the frame in flight: a frame accepted gets
  exactly one reply. Each detection is

      %{class_id: 0..79, score: 0.0..1.0, x0: _, y0: _, x1: _, y1: _}

  in **the submitted image's** pixel coordinates. Every backend owns
  its own letterbox/resize transform in both directions, so a caller
  never has to know the model's input size. Getting this wrong is
  invisible until boxes land in the wrong place, which is why it is
  stated here rather than left to each implementation.

  ## Unavailable is a normal state, not an error

  A backend that cannot work — no accelerator, no model file — must
  start anyway, log once, and answer
  `{:error, :unavailable}` for every frame. Raising in `init/1` would
  take down the supervision tree, and a vision unit that loses
  *stereo depth* because a detector could not find its model file is a
  far worse outcome than one that publishes no detections.

  `available?/1` exists so a caller can say something useful at
  startup instead of discovering this per-frame.

  ## The accelerator

  `npu_kind/0` names the accelerator a backend runs on, as the
  dashboard shows it, or `nil` for a backend that runs on none.

  ## The inference time

  A backend whose Port reports the accelerator time of each inference
  keeps the sum and the count of those times, and `inference_times/1`
  hands them over and starts them again: the status reads them once per
  tick. It answers `nil` until the Port has reported a time, as a backend
  without a Port, or one of an older build, never does. What the time is
  depends on the accelerator: see `docs/vision/README.md`.

  ## The inference step

  A backend declares the inference step of its detection pipeline, its
  `:pipeline` option, in `VisionCore.Parameters` when it starts, built
  with `VisionCore.Detection.Pipeline.inference_group/2`: what it runs,
  where, and its settings.

  ## Its name

  A backend registers under its `:name` option, the module by default;
  `VisionCore.Detection.Supervisor` gives each pipeline's backend its own
  (`VisionCore.Detection.server/2`), and `detect/3`, `available?/1` and
  `inference_times/1` take it.
  """

  @typedoc "A 2D box in the submitted image's pixel coordinates."
  @type detection :: %{
          class_id: non_neg_integer(),
          score: float(),
          x0: number(),
          y0: number(),
          x1: number(),
          y1: number()
        }

  @typedoc "Whatever `start_link/1` registered the backend as."
  @type server :: GenServer.server()

  @doc """
  Submit one image, a `u8` tensor, `{height, width}` grey or
  `{height, width, 3}` RGB, for detection, tagged with `sequence`. The
  backend shrinks it whole to its model's input, letterboxed.

  `:ok` means the frame was accepted and a reply will follow.
  `{:error, :busy}` means one is already in flight and this frame was
  dropped. `{:error, :unavailable}` means the backend is not working
  and never will be without a restart.
  """
  @callback detect(server(), sequence :: non_neg_integer(), image :: Nx.Tensor.t()) ::
              :ok | {:error, :busy | :unavailable}

  @doc "False when the backend could not initialise. Never raises."
  @callback available?(server()) :: boolean()

  @doc """
  Where the backend is: `:starting` while it prepares its model and
  opens its accelerator, `:running` once it takes frames, `:failed` when it
  does not and is not about to. Never raises. Without it,
  `available?/1` tells `:running` from `:failed`.
  """
  @callback state(GenServer.server()) :: :starting | :running | :failed

  @optional_callbacks state: 1

  @doc """
  The options the backend takes beside `:name` and those its unit's
  supervisor gives it: the supervisor hands it these of the unit's
  options, and refuses the unit one that neither it nor the backend
  takes.
  """
  @callback options() :: [atom()]

  @doc "The kind of accelerator the backend runs on, `nil` without one."
  @callback npu_kind() :: String.t() | nil

  @doc """
  The inference times, in microseconds, of the frames answered since the
  last call: their sum and their count. Starts them again.
  """
  @callback inference_times(server()) ::
              %{sum_us: non_neg_integer(), count: non_neg_integer()} | nil
end
