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
  reason — see `decode/6`.

  ## Options

    * `:model_path` (required) — an ONNX YOLO model. The Hailo's
      `yolov8n.hef` is fetched by `mise run fetch-models`
      (`scripts/models.tsv`); this wants the `.onnx` export of an
      equivalent model, which is neither committed nor fetched — see
      `docs/ros2_perception.md`.
    * `:target` (`:cpu`) — as above.
    * `:score_threshold` (`0.4`), `:nms_threshold` (`0.45`).
    * `:input_size` (`640`) — the square the model expects.
  """
  use GenServer

  @behaviour RosBridge.Inference

  require Logger

  @default_score_threshold 0.4
  @default_nms_threshold 0.45
  # The standard YOLOv8 export input size.
  @default_input_size 640
  # `handle_call/3` replies at once; this only bounds a wedged server.
  @detect_call_timeout_ms 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl RosBridge.Inference
  def detect(server \\ __MODULE__, sequence, mat) do
    GenServer.call(server, {:detect, sequence, mat, self()}, @detect_call_timeout_ms)
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

  @impl GenServer
  def init(opts) do
    model_path = Keyword.fetch!(opts, :model_path)

    state = %{
      net: nil,
      worker: nil,
      sequence: nil,
      reply_to: nil,
      target: Keyword.get(opts, :target, :cpu),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      nms_threshold: Keyword.get(opts, :nms_threshold, @default_nms_threshold),
      input_size: Keyword.get(opts, :input_size, @default_input_size),
      model_path: model_path
    }

    {:ok, load_model(state)}
  end

  # `spawn_monitor`, not `Task.async`: a crashing inference must not take the backend down.
  @impl GenServer
  def handle_call({:detect, _sequence, _mat, _reply_to}, _from, %{net: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, _sequence, _mat, _reply_to}, _from, %{worker: {_pid, _ref}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:detect, sequence, mat, reply_to}, _from, state) do
    parent = self()
    worker = spawn_monitor(fn -> send(parent, {:inferred, self(), infer(state, mat)}) end)
    {:reply, :ok, %{state | worker: worker, sequence: sequence, reply_to: reply_to}}
  end

  def handle_call(:available?, _from, state), do: {:reply, not is_nil(state.net), state}

  def handle_call(:busy?, _from, state), do: {:reply, not is_nil(state.worker), state}

  @impl GenServer
  def handle_info({:inferred, pid, detections}, %{worker: {pid, monitor_reference}} = state) do
    Process.demonitor(monitor_reference, [:flush])
    send(state.reply_to, {:inference_detections, state.sequence, detections})
    {:noreply, %{state | worker: nil, reply_to: nil}}
  end

  # A crashed inference drops its frame; no reply is sent.
  def handle_info(
        {:DOWN, monitor_reference, :process, pid, reason},
        %{worker: {pid, monitor_reference}} = state
      ) do
    Logger.warning("#{__MODULE__}: inference process died: #{inspect(reason)} — frame dropped")
    {:noreply, %{state | worker: nil, reply_to: nil}}
  end

  # A late message from a worker already accounted for.
  def handle_info(_message, state), do: {:noreply, state}

  defp load_model(state) do
    if File.exists?(state.model_path) do
      read_net(state)
    else
      Logger.error(
        "#{__MODULE__}: no model at #{state.model_path} — detections disabled. " <>
          "See docs/ros2_perception.md for obtaining one."
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
        # Evision returns errors instead of raising.
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

  # Also returns a phrase for the log, so a fallback is visible.
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

  defp dnn_backend_opencv, do: Evision.Constant.cv_DNN_BACKEND_OPENCV()
  defp dnn_target_cpu, do: Evision.Constant.cv_DNN_TARGET_CPU()
  defp dnn_target_opencl, do: Evision.Constant.cv_DNN_TARGET_OPENCL()
  defp dnn_target_opencl_fp16, do: Evision.Constant.cv_DNN_TARGET_OPENCL_FP16()

  defp infer(state, mat) do
    {height, width} = mat_shape(mat)
    input_size = state.input_size

    blob =
      mat
      |> to_three_channel()
      |> Evision.DNN.blobFromImage(
        scalefactor: 1.0 / 255.0,
        size: {input_size, input_size},
        swapRB: true,
        crop: false
      )

    with %Evision.Mat{} = blob <- blob,
         net = Evision.DNN.Net.setInput(state.net, blob),
         outputs when not is_tuple(outputs) <- Evision.DNN.Net.forward(net),
         %Evision.Mat{} = output <- first_output(outputs) do
      decode(output, width, height, input_size, state.score_threshold, state.nms_threshold)
    else
      other ->
        # Evision returns `{:error, message}` instead of raising; the frame is dropped.
        log_inference_failure(other)
        []
    end
  end

  # Failures repeat every frame: log the first, then every Nth with the count.
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

  # `Net.forward/1` returns a list of Mats, one per output layer.
  defp first_output([%Evision.Mat{} = mat | _]), do: mat
  defp first_output(%Evision.Mat{} = mat), do: mat
  defp first_output(other), do: other

  # The stereo pipeline hands a grayscale frame; YOLO needs three channels.
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

  # Guarded: Evision's `{:error, message}` would otherwise match `{height, width}`.
  defp mat_shape(mat) do
    case Evision.Mat.shape(mat) do
      {height, width} when is_integer(height) and is_integer(width) -> {height, width}
      {height, width, _channels} when is_integer(height) and is_integer(width) -> {height, width}
      _other -> {0, 0}
    end
  end

  @doc """
  Turn one YOLO output into boxes in the source image's pixels.

  Takes the output `Evision.Mat` — `{1, 4 + classes, anchors}` or the
  same without the batch — rather than a flat list:

    * The class count comes from the shape, so any class count decodes,
      not only COCO's 80.

    * The per-anchor maximum is taken in native code (`Evision.reduce/4`):
      Nx's default backend is pure Elixir and far too slow for the
      stereo frame rate.

  Elixir only touches the per-anchor maxima and the handful of anchors
  that clear the threshold.
  """
  def decode(output, width, height, input_size, score_threshold, nms_threshold) do
    case attribute_major(output) do
      {mat, attributes, anchors} ->
        mat
        |> candidates(attributes, anchors, score_threshold)
        |> Enum.map(&to_pixels(&1, width, height, input_size))
        |> non_max_suppression(nms_threshold)

      :error ->
        []
    end
  end

  # Normalises the output to 2D `{attributes, anchors}`; other shapes are refused.
  defp attribute_major(output) do
    with %Evision.Mat{} = mat <- output,
         shape <- Evision.Mat.shape(mat),
         {attributes, anchors} <- two_dimensional(shape),
         true <- attributes > 4 and anchors > 0,
         %Evision.Mat{} = flat <- reshape_2d(mat, shape, attributes, anchors) do
      {flat, attributes, anchors}
    else
      _other -> :error
    end
  end

  defp two_dimensional({1, attributes, anchors}), do: {attributes, anchors}
  defp two_dimensional({attributes, anchors}), do: {attributes, anchors}
  defp two_dimensional(_other), do: :error

  defp reshape_2d(mat, {_batch, _attributes, _anchors}, attributes, anchors),
    do: Evision.Mat.reshape(mat, [attributes, anchors])

  defp reshape_2d(mat, _shape, _attributes, _anchors), do: mat

  # Attribute-major: an anchor's cx and cy are `anchors` elements apart.
  defp candidates(mat, attributes, anchors, threshold) do
    classes = attributes - 4

    # `roi/2` takes `{x, y, width, height}`, so these are full-width
    # row bands: the four box attributes, then every class score.
    with %Evision.Mat{} = boxes <- Evision.Mat.roi(mat, {0, 0, anchors, 4}),
         %Evision.Mat{} = scores <- Evision.Mat.roi(mat, {0, 4, anchors, classes}),
         %Evision.Mat{} = max_scores <- reduce_max_per_anchor(scores),
         box_binary when is_binary(box_binary) <- Evision.Mat.to_binary(boxes),
         score_binary when is_binary(score_binary) <- Evision.Mat.to_binary(scores),
         max_binary when is_binary(max_binary) <- Evision.Mat.to_binary(max_scores) do
      for {score, anchor} <- Enum.with_index(floats(max_binary)), score >= threshold do
        %{
          cx: float_at(box_binary, anchor),
          cy: float_at(box_binary, anchors + anchor),
          width: float_at(box_binary, 2 * anchors + anchor),
          height: float_at(box_binary, 3 * anchors + anchor),
          score: score,
          class_id: best_class(score_binary, anchor, anchors, classes)
        }
      end
    else
      _other -> []
    end
  end

  # Reduces down the class rows: one maximum per anchor.
  defp reduce_max_per_anchor(scores) do
    Evision.reduce(scores, 0, Evision.Constant.cv_REDUCE_MAX(), dtype: Evision.Constant.cv_32F())
  end

  # Called only for anchors above the threshold.
  defp best_class(score_binary, anchor, anchors, classes) do
    Enum.reduce(0..(classes - 1), {-1.0, 0}, fn class_id, {best, best_id} ->
      score = float_at(score_binary, class_id * anchors + anchor)
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

  # Plain resize (`crop: false`, no letterbox): one scale factor per axis.
  defp to_pixels(candidate, width, height, input_size) do
    scale_x = width / input_size
    scale_y = height / input_size

    %{
      class_id: candidate.class_id,
      score: candidate.score,
      x0: (candidate.cx - candidate.width / 2) * scale_x,
      y0: (candidate.cy - candidate.height / 2) * scale_y,
      x1: (candidate.cx + candidate.width / 2) * scale_x,
      y1: (candidate.cy + candidate.height / 2) * scale_y
    }
  end

  # Greedy per-class NMS in Elixir, so it is testable without Evision.
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

  defp iou(box, other_box) do
    x0 = max(box.x0, other_box.x0)
    y0 = max(box.y0, other_box.y0)
    x1 = min(box.x1, other_box.x1)
    y1 = min(box.y1, other_box.y1)
    overlap = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    box_area = max(0.0, box.x1 - box.x0) * max(0.0, box.y1 - box.y0)
    other_area = max(0.0, other_box.x1 - other_box.x0) * max(0.0, other_box.y1 - other_box.y0)
    union = box_area + other_area - overlap
    if union <= 0.0, do: 0.0, else: overlap / union
  end
end
