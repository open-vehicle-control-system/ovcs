defmodule RosBridge.Inference.Stub do
  @moduledoc """
  A detection backend that runs no model and invents its boxes.

  For proving the *plumbing* when neither an accelerator nor a model
  file is available: that `Detections` fuses a box with the depth map,
  unprojects it, and that the markers and `Detection3DArray` reach a
  viewer. None of that involves a neural network, and all of it can be
  wrong.

  Not the default anywhere, and it says so in its logs on every start.
  A backend that fabricates measurements is genuinely dangerous to
  leave wired in by accident — boxes on a screen look equally
  convincing whether or not anything detected them — so it has to be
  asked for by name.

  Boxes are a fixed fraction of the submitted frame rather than fixed
  pixels, so the same config produces a sane box at any resolution.
  The default is one box in the middle third of the image: with the
  simulator's `workshop.sdf` that lands on the boxes the world puts in
  front of the camera, so the fused distance is checkable against the
  world rather than merely plausible.

  ## Opts

    * `:boxes` — a list of `{class_id, score, {x0, y0, x1, y1}}` with
      the coordinates as 0.0–1.0 fractions of width/height. Defaults to
      a single centred box classed as `person` (COCO 0).
  """
  use GenServer

  @behaviour RosBridge.Inference

  require Logger

  @default_boxes [{0, 0.99, {0.33, 0.33, 0.67, 0.67}}]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl RosBridge.Inference
  def detect(server \\ __MODULE__, seq, mat) do
    GenServer.call(server, {:detect, seq, mat, self()})
  end

  @impl RosBridge.Inference
  def available?(_server \\ __MODULE__), do: true

  @impl RosBridge.Inference
  def busy?(_server \\ __MODULE__), do: false

  @impl true
  def init(opts) do
    boxes = Keyword.get(opts, :boxes, @default_boxes)

    Logger.warning(
      "#{__MODULE__}: fabricating #{length(boxes)} detection(s) per frame — " <>
        "no model is running. Never enable this on a vehicle."
    )

    {:ok, %{boxes: boxes}}
  end

  @impl true
  def handle_call({:detect, seq, mat, reply_to}, _from, state) do
    {height, width} = shape(mat)

    detections =
      for {class_id, score, {x0, y0, x1, y1}} <- state.boxes do
        %{
          class_id: class_id,
          score: score,
          x0: x0 * width,
          y0: y0 * height,
          x1: x1 * width,
          y1: y1 * height
        }
      end

    send(reply_to, {:inference_detections, seq, detections})
    {:reply, :ok, state}
  end

  defp shape(mat) do
    case Evision.Mat.shape(mat) do
      {h, w} -> {h, w}
      {h, w, _channels} -> {h, w}
    end
  end
end
