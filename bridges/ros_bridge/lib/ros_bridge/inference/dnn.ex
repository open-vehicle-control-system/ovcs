defmodule RosBridge.Inference.Dnn do
  @moduledoc """
  YOLO inference through OpenCV's DNN module, on the CPU or on a GPU
  via OpenCL. What lets the full perception stack run on a
  workstation, simulator included, with no accelerator.

  Same contract as `RosBridge.Inference.Hailo`, so
  `RosBridge.Publishers.Detections` cannot tell them apart. Evision is
  already a dependency — it is what runs SGBM — so this adds no native
  build and no system package.

  ## CPU and GPU are one module, not two

  They differ by two calls, `setPreferableBackend/2` and
  `setPreferableTarget/2`. Model loading, blob preparation, output
  decoding and NMS are identical, so splitting them would mean two
  copies of the fiddly part to keep in step. `:target` picks:

    * `:cpu` — always available.
    * `:opencl` — FP32 on any OpenCL device.
    * `:opencl_fp16` — half precision, usually the faster of the two
      on a discrete GPU.

  ### On NVIDIA hardware, expect less than you might hope

  OpenCV's OpenCL DNN kernels are far less tuned than its CUDA ones,
  so OpenCL on an NVIDIA card typically lands around 1.5–3x CPU rather
  than the 10x+ a CUDA/cuDNN path would give. It is real GPU
  execution, and it is free here; a CUDA target would need OpenCV
  rebuilt against CUDA + cuDNN, which means giving up the precompiled
  Evision.

  ## Falling back is explicit

  Asking for `:opencl` where no OpenCL device exists **does not**
  silently run on the CPU pretending otherwise. It logs the reason
  once and continues on the CPU, so a machine that quietly lost its
  GPU shows up in the log rather than as an unexplained slowdown.

  A missing or unreadable model leaves this process alive and
  answering `{:error, :unavailable}`, per the contract in
  `RosBridge.Inference`: losing detections is acceptable, taking the
  stereo depth path down with it is not.

  ## Nothing here blocks the caller

  `detect/3` hands the frame to a monitored child process and returns.
  That is `RosBridge.Inference`'s contract — "asynchronous and lossy" —
  and on the CPU target it is load-bearing rather than decorative: the
  caller is `RosBridge.Publishers.Detections`, which drives the stereo
  *depth* path from the same process, so a frame taking 800 ms inline
  would stall depth for 800 ms, and one exceeding the call timeout
  would crash `Detections` outright. A frame arriving mid-inference is
  refused with `{:error, :busy}`; an inference that crashes drops its
  frame and leaves the backend up.

  The output decode is native rather than `Nx`, for the same class of
  reason — see `decode/6`, where it was worth 340 ms a frame.

  ## Opts

    * `:model_path` (required) — an ONNX YOLO model. The repo ships
      `yolov8n.hef` for the Hailo; this wants the `.onnx` export of an
      equivalent model, which is **not** committed — see
      `docs/ros_perception_detection.md`.
    * `:target` (`:cpu`) — as above.
    * `:score_threshold` (`0.4`), `:nms_threshold` (`0.45`).
    * `:input_size` (`640`) — the square the model expects.
  """
  use GenServer

  @behaviour RosBridge.Inference

  require Logger

  @default_score_threshold 0.4
  @default_nms_threshold 0.45
  @default_input_size 640

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl RosBridge.Inference
  def detect(server \\ __MODULE__, seq, mat) do
    GenServer.call(server, {:detect, seq, mat, self()}, 10_000)
  end

  @impl RosBridge.Inference
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @impl RosBridge.Inference
  def busy?(server \\ __MODULE__) do
    GenServer.call(server, :busy?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    model_path = Keyword.fetch!(opts, :model_path)

    state = %{
      net: nil,
      worker: nil,
      seq: nil,
      reply_to: nil,
      target: Keyword.get(opts, :target, :cpu),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      nms_threshold: Keyword.get(opts, :nms_threshold, @default_nms_threshold),
      input_size: Keyword.get(opts, :input_size, @default_input_size),
      model_path: model_path
    }

    {:ok, load(state)}
  end

  # Inference runs in a monitored child process, and `detect/3` returns
  # the moment the frame is handed over. `RosBridge.Inference` requires
  # that — "asynchronous and lossy" — and it is not a stylistic point:
  # the caller is `Detections`, which also drives the *stereo depth*
  # path. A CPU frame that takes 800 ms would stall depth for 800 ms,
  # and one that took longer than the call timeout would crash
  # `Detections` outright, which is precisely the outcome the
  # behaviour doc says must not happen.
  #
  # `spawn_monitor` rather than `Task.async`: an inference that crashes
  # must drop its frame, not take the backend down with it, and an
  # `async` Task is linked.
  @impl true
  def handle_call({:detect, _seq, _mat, _reply_to}, _from, %{net: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, _seq, _mat, _reply_to}, _from, %{worker: {_pid, _ref}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:detect, seq, mat, reply_to}, _from, state) do
    parent = self()
    worker = spawn_monitor(fn -> send(parent, {:inferred, self(), infer(state, mat)}) end)
    {:reply, :ok, %{state | worker: worker, seq: seq, reply_to: reply_to}}
  end

  def handle_call(:available?, _from, state), do: {:reply, not is_nil(state.net), state}

  def handle_call(:busy?, _from, state), do: {:reply, not is_nil(state.worker), state}

  @impl true
  def handle_info({:inferred, pid, detections}, %{worker: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    send(state.reply_to, {:inference_detections, state.seq, detections})
    {:noreply, %{state | worker: nil, reply_to: nil}}
  end

  # A crashed inference drops the frame. No reply is sent, so
  # `Detections` clears its pending frame on the next one rather than
  # waiting on boxes that will never come.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{worker: {pid, ref}} = state) do
    Logger.warning("#{__MODULE__}: inference process died: #{inspect(reason)} — frame dropped")
    {:noreply, %{state | worker: nil, reply_to: nil}}
  end

  # A late message from a worker already accounted for.
  def handle_info(_message, state), do: {:noreply, state}

  defp load(state) do
    if File.exists?(state.model_path) do
      read_net(state)
    else
      Logger.error(
        "#{__MODULE__}: no model at #{state.model_path} — detections disabled. " <>
          "See docs/ros_perception_detection.md for obtaining one."
      )

      state
    end
  end

  defp read_net(state) do
    case Evision.DNN.readNetFromONNX(state.model_path) do
      %Evision.DNN.Net{} = net ->
        {backend, target, note} = resolve_target(state.target)
        net = Evision.DNN.Net.setPreferableBackend(net, backend)
        net = Evision.DNN.Net.setPreferableTarget(net, target)
        Logger.info("#{__MODULE__}: #{Path.basename(state.model_path)} loaded, #{note}")
        %{state | net: net}

      other ->
        # Again a return value, not an exception.
        Logger.error(
          "#{__MODULE__}: could not load #{state.model_path}: " <>
            "#{inspect(other) |> String.slice(0, 200)} — detections disabled"
        )

        state
    end
  rescue
    error ->
      Logger.error("#{__MODULE__}: could not load #{state.model_path}: #{inspect(error)}")
      state
  end

  # Returns the backend/target pair and a phrase for the log, so the
  # fallback is visible rather than inferred from a missing speedup.
  defp resolve_target(:cpu), do: {dnn_backend_opencv(), dnn_target_cpu(), "running on the CPU"}

  defp resolve_target(requested) when requested in [:opencl, :opencl_fp16] do
    if opencl_available?() do
      target =
        if requested == :opencl_fp16,
          do: dnn_target_opencl_fp16(),
          else: dnn_target_opencl()

      {dnn_backend_opencv(), target, "running on #{opencl_device_name()} via #{requested}"}
    else
      Logger.warning(
        "#{__MODULE__}: #{requested} requested but no OpenCL device is usable — " <>
          "falling back to the CPU"
      )

      resolve_target(:cpu)
    end
  end

  defp opencl_available? do
    Evision.OCL.haveOpenCL() and Evision.OCL.useOpenCL()
  rescue
    _ -> false
  end

  defp opencl_device_name do
    Evision.OCL.Device.getDefault() |> Evision.OCL.Device.name()
  rescue
    _ -> "an OpenCL device"
  end

  # Evision exposes the cv::dnn enums as functions; naming them here
  # keeps the constants in one place and the call sites readable.
  defp dnn_backend_opencv, do: Evision.Constant.cv_DNN_BACKEND_OPENCV()
  defp dnn_target_cpu, do: Evision.Constant.cv_DNN_TARGET_CPU()
  defp dnn_target_opencl, do: Evision.Constant.cv_DNN_TARGET_OPENCL()
  defp dnn_target_opencl_fp16, do: Evision.Constant.cv_DNN_TARGET_OPENCL_FP16()

  defp infer(state, mat) do
    {height, width} = mat_shape(mat)
    size = state.input_size

    blob =
      mat
      |> to_three_channel()
      |> Evision.DNN.blobFromImage(
        scalefactor: 1.0 / 255.0,
        size: {size, size},
        swapRB: true,
        crop: false
      )

    with %Evision.Mat{} = blob <- blob,
         net = Evision.DNN.Net.setInput(state.net, blob),
         outputs when not is_tuple(outputs) <- Evision.DNN.Net.forward(net),
         %Evision.Mat{} = out <- first_output(outputs) do
      decode(out, width, height, size, state.score_threshold, state.nms_threshold)
    else
      other ->
        # Evision signals failure by *returning* `{:error, message}`
        # rather than raising, so this has to be matched rather than
        # rescued. A frame that cannot be inferred is dropped, not
        # crashed on — same as a busy accelerator.
        log_inference_failure(other)
        []
    end
  end

  # A failure that is going to happen at all happens on every frame —
  # a channel-count mismatch, a model that will not run on the chosen
  # target — so logging each one buries the rest of the log at the
  # stereo rate. The first is loud; after that, one line per hundred
  # with the count, which is enough to see it is still happening
  # without drowning anything else.
  @failure_log_interval 100

  defp log_inference_failure(reason) do
    count = :persistent_term.get({__MODULE__, :failures}, 0) + 1
    :persistent_term.put({__MODULE__, :failures}, count)

    if count == 1 or rem(count, @failure_log_interval) == 0 do
      Logger.warning(
        "#{__MODULE__}: inference failed (#{count} so far): " <>
          "#{inspect(reason) |> String.slice(0, 200)}"
      )
    end
  end

  # `Net.forward/1` answers with a *list* of Mats, one per output layer,
  # even for a single-output model. Treating it as a Mat is the kind of
  # mistake that only shows up the first time real inference runs.
  defp first_output([%Evision.Mat{} = mat | _]), do: mat
  defp first_output(%Evision.Mat{} = mat), do: mat
  defp first_output(other), do: other

  # The frame this is handed is `Result.left_rectified`, which is
  # **grayscale**: SGBM needs single-channel input, so that is what the
  # stereo pipeline rectifies and keeps. Every YOLO export expects
  # three, and OpenCV does not broadcast — it refuses the graph with
  # "Number of input channels should be multiple of 3 but got 1", once
  # per frame, which is how this was found. Converting is a copy of a
  # 640x480 mono frame and cheap next to the inference.
  defp to_three_channel(mat) do
    case Evision.Mat.shape(mat) do
      {_height, _width} ->
        Evision.cvtColor(mat, Evision.Constant.cv_COLOR_GRAY2BGR())

      {_height, _width, 1} ->
        Evision.cvtColor(mat, Evision.Constant.cv_COLOR_GRAY2BGR())

      _already_colour ->
        mat
    end
  end

  # `Evision.Mat.shape/1` signals failure the way the rest of Evision
  # does, by returning `{:error, message}` — which is a two-tuple, and
  # so would match a `{height, width}` clause and put a binary into the
  # arithmetic further down. Hence the guards.
  defp mat_shape(mat) do
    case Evision.Mat.shape(mat) do
      {h, w} when is_integer(h) and is_integer(w) -> {h, w}
      {h, w, _channels} when is_integer(h) and is_integer(w) -> {h, w}
      _other -> {0, 0}
    end
  end

  @doc """
  Turn one YOLO output into boxes in the source image's pixels.

  Takes the output `Evision.Mat` — `{1, 4 + classes, anchors}` or the
  same without the batch — rather than a flat list, for two reasons
  that were both defects here:

    * The class count has to come from the shape. It was hardcoded to
      84 (4 box + 80 COCO classes), which made every other model — a
      single-class person detector, a retrained head — decode as
      nothing at all, silently, because the flat length no longer
      divided by 84.

    * The per-anchor maximum has to be taken in native code. Doing it
      in Nx cost **340 ms** of a 397 ms decode for a real yolov8n
      output (84 x 8400), because Nx's default backend is pure Elixir:
      a 1.8 fps ceiling on the decode alone, against a 30 Hz stereo
      pipeline. `Evision.reduce/4` does the same 672,000-element pass
      in 1.7 ms. The tests had used a 2x2 input with 4 anchors and so
      never went anywhere near it.

  So OpenCV reduces, and Elixir only touches the 8,400 maxima and the
  handful of anchors that clear the threshold.
  """
  def decode(out, width, height, input_size, score_threshold, nms_threshold) do
    case attribute_major(out) do
      {mat, attrs, anchors} ->
        mat
        |> candidates(attrs, anchors, score_threshold)
        |> Enum.map(&to_pixels(&1, width, height, input_size))
        |> non_max_suppression(nms_threshold)

      :error ->
        []
    end
  end

  # `Net.forward/1` gives `{1, attrs, anchors}`. Everything below works
  # on the 2D form, and anything that is not one of these two shapes is
  # refused rather than decoded into nonsense.
  defp attribute_major(out) do
    with %Evision.Mat{} = mat <- out,
         shape <- Evision.Mat.shape(mat),
         {attrs, anchors} <- two_dimensional(shape),
         true <- attrs > 4 and anchors > 0,
         %Evision.Mat{} = flat <- reshape_2d(mat, shape, attrs, anchors) do
      {flat, attrs, anchors}
    else
      _other -> :error
    end
  end

  defp two_dimensional({1, attrs, anchors}), do: {attrs, anchors}
  defp two_dimensional({attrs, anchors}), do: {attrs, anchors}
  defp two_dimensional(_other), do: :error

  defp reshape_2d(mat, {_batch, _attrs, _anchors}, attrs, anchors),
    do: Evision.Mat.reshape(mat, [attrs, anchors])

  defp reshape_2d(mat, _shape, _attrs, _anchors), do: mat

  # yolov8 output is attribute-major: every anchor's cx sits `anchors`
  # elements from its cy, not next to it. Reading it row-major is the
  # classic way to get boxes that look almost right.
  defp candidates(mat, attrs, anchors, threshold) do
    classes = attrs - 4

    # `roi/2` takes `{x, y, width, height}`, so these are full-width
    # row bands: the four box attributes, then every class score.
    with %Evision.Mat{} = boxes <- Evision.Mat.roi(mat, {0, 0, anchors, 4}),
         %Evision.Mat{} = scores <- Evision.Mat.roi(mat, {0, 4, anchors, classes}),
         %Evision.Mat{} = maxes <- reduce_max_per_anchor(scores),
         box_bin when is_binary(box_bin) <- Evision.Mat.to_binary(boxes),
         score_bin when is_binary(score_bin) <- Evision.Mat.to_binary(scores),
         max_bin when is_binary(max_bin) <- Evision.Mat.to_binary(maxes) do
      for {score, a} <- Enum.with_index(floats(max_bin)), score >= threshold do
        %{
          cx: float_at(box_bin, a),
          cy: float_at(box_bin, anchors + a),
          w: float_at(box_bin, 2 * anchors + a),
          h: float_at(box_bin, 3 * anchors + a),
          score: score,
          class_id: best_class(score_bin, a, anchors, classes)
        }
      end
    else
      _other -> []
    end
  end

  # Along dimension 0, i.e. down the class rows, giving one maximum per
  # anchor. This is the call that replaced 340 ms of Nx with 1.7 ms.
  defp reduce_max_per_anchor(scores) do
    Evision.reduce(scores, 0, Evision.Constant.cv_REDUCE_MAX(), dtype: Evision.Constant.cv_32F())
  end

  # Only ever called for an anchor that already cleared the threshold,
  # so this walks `classes` floats a handful of times per frame rather
  # than `classes * anchors` every time.
  defp best_class(score_bin, anchor, anchors, classes) do
    Enum.reduce(0..(classes - 1), {-1.0, 0}, fn class_id, {best, best_id} ->
      score = float_at(score_bin, class_id * anchors + anchor)
      if score > best, do: {score, class_id}, else: {best, best_id}
    end)
    |> elem(1)
  end

  # The output is CV_32F, so four bytes per element and a plain offset.
  defp float_at(binary, index) do
    <<value::float-32-little>> = binary_part(binary, index * 4, 4)
    value
  end

  defp floats(binary), do: for(<<value::float-32-little <- binary>>, do: value)

  # The blob was a plain resize (`crop: false`, no letterbox), so the
  # inverse is one scale factor per axis.
  defp to_pixels(d, width, height, input_size) do
    sx = width / input_size
    sy = height / input_size

    %{
      class_id: d.class_id,
      score: d.score,
      x0: (d.cx - d.w / 2) * sx,
      y0: (d.cy - d.h / 2) * sy,
      x1: (d.cx + d.w / 2) * sx,
      y1: (d.cy + d.h / 2) * sy
    }
  end

  # Greedy NMS, per class. Done here rather than through
  # `Evision.DNN.nmsBoxes/4` so the whole decode stays a pure function
  # over numbers and can be tested without Evision in the loop.
  defp non_max_suppression(detections, threshold) do
    detections
    |> Enum.group_by(& &1.class_id)
    |> Enum.flat_map(fn {_class, group} ->
      suppress(Enum.sort_by(group, & &1.score, :desc), [], threshold)
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp suppress([], kept, _threshold), do: Enum.reverse(kept)

  defp suppress([best | rest], kept, threshold) do
    rest = Enum.reject(rest, &(iou(best, &1) > threshold))
    suppress(rest, [best | kept], threshold)
  end

  defp iou(a, b) do
    x0 = max(a.x0, b.x0)
    y0 = max(a.y0, b.y0)
    x1 = min(a.x1, b.x1)
    y1 = min(a.y1, b.y1)
    overlap = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    area_a = max(0.0, a.x1 - a.x0) * max(0.0, a.y1 - a.y0)
    area_b = max(0.0, b.x1 - b.x0) * max(0.0, b.y1 - b.y0)
    union = area_a + area_b - overlap
    if union <= 0.0, do: 0.0, else: overlap / union
  end
end
