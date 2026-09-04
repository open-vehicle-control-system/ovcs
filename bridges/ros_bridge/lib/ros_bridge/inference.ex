defmodule RosBridge.Inference do
  @moduledoc """
  What a detection backend has to do, so the stereo pipeline does not
  care which one it is talking to.

  There are three, and they differ only in where the arithmetic
  happens:

    * `RosBridge.Inference.Hailo` — a YOLO HEF on a Hailo-8, via a
      Port. What runs on the car.
    * `RosBridge.Inference.Dnn` — OpenCV's DNN module, on the CPU or
      on a GPU through OpenCL. What lets the full stack run on a
      workstation, simulator included.
    * `RosBridge.Inference.Stub` — fixed boxes, no model. For proving
      the plumbing when neither of the above is available.

  ## The contract

  `detect/3` is **asynchronous and lossy**. It hands a frame over and
  returns immediately; the boxes arrive later as a message. A frame
  submitted while another is in flight is *dropped*, not queued —
  `{:error, :busy}`. That is deliberate for a live sensor: queueing
  would add latency to a measurement whose only value is being
  current.

  The reply is

      {:inference_detections, seq, detections}

  where `seq` is the sequence number the caller passed to `detect/3`,
  and each detection is

      %{class_id: 0..79, score: 0.0..1.0, x0: _, y0: _, x1: _, y1: _}

  in **the submitted image's** pixel coordinates. Every backend owns
  its own letterbox/resize transform in both directions, so a caller
  never has to know the model's input size. Getting this wrong is
  invisible until boxes land in the wrong place, which is why it is
  stated here rather than left to each implementation.

  ## Unavailable is a normal state, not an error

  A backend that cannot work — no accelerator, no model file, no
  OpenCL device — must start anyway, log once, and answer
  `{:error, :unavailable}` for every frame. Raising in `init/1` would
  take down the supervision tree, and a perception bridge that loses
  *stereo depth* because a detector could not find its model file is a
  far worse outcome than one that publishes no detections.

  `available?/1` exists so a caller can say something useful at
  startup instead of discovering this per-frame.
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
  Submit one `Evision.Mat` for detection, tagged with `seq`.

  `:ok` means the frame was accepted and a reply will follow.
  `{:error, :busy}` means one is already in flight and this frame was
  dropped. `{:error, :unavailable}` means the backend is not working
  and never will be without a restart.
  """
  @callback detect(server(), seq :: non_neg_integer(), mat :: Evision.Mat.maybe_mat_in()) ::
              :ok | {:error, :busy | :unavailable}

  @doc "False when the backend could not initialise. Never raises."
  @callback available?(server()) :: boolean()

  @doc "True while an inference is in flight."
  @callback busy?(server()) :: boolean()
end
