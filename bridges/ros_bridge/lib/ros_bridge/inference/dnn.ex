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
      target: Keyword.get(opts, :target, :cpu),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      nms_threshold: Keyword.get(opts, :nms_threshold, @default_nms_threshold),
      input_size: Keyword.get(opts, :input_size, @default_input_size),
      model_path: model_path
    }

    {:ok, load(state)}
  end

  # Inference runs inline in the GenServer rather than in a Task: it is
  # the only thing this process does, and running one at a time is the
  # backpressure. `detect/3` is still a call, so a slow CPU frame
  # blocks the caller instead of silently queueing — the caller is
  # `Detections`, whose next frame would be dropped as `:busy` anyway.
  @impl true
  def handle_call({:detect, _seq, _mat, _reply_to}, _from, %{net: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:detect, seq, mat, reply_to}, _from, state) do
    detections = infer(state, mat)
    send(reply_to, {:inference_detections, seq, detections})
    {:reply, :ok, state}
  end

  def handle_call(:available?, _from, state), do: {:reply, not is_nil(state.net), state}

  # Never busy from the caller's point of view: `detect/3` does not
  # return until the frame is done, so there is no window in which a
  # second frame could arrive mid-inference.
  def handle_call(:busy?, _from, state), do: {:reply, false, state}

  defp load(state) do
    cond do
      not File.exists?(state.model_path) ->
        Logger.error(
          "#{__MODULE__}: no model at #{state.model_path} — detections disabled. " <>
            "See docs/ros_perception_detection.md for obtaining one."
        )

        state

      true ->
        read_net(state)
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
      Evision.DNN.blobFromImage(mat,
        scalefactor: 1.0 / 255.0,
        size: {size, size},
        swapRB: true,
        crop: false
      )

    with %Evision.Mat{} = blob <- blob,
         net = Evision.DNN.Net.setInput(state.net, blob),
         outputs when not is_tuple(outputs) <- Evision.DNN.Net.forward(net),
         %Evision.Mat{} = out <- first_output(outputs) do
      out
      |> Evision.Mat.to_nx()
      |> Nx.to_flat_list()
      |> decode(width, height, size, state.score_threshold, state.nms_threshold)
    else
      other ->
        # Evision signals failure by *returning* `{:error, message}`
        # rather than raising, so this has to be matched rather than
        # rescued. A frame that cannot be inferred is dropped, not
        # crashed on — same as a busy accelerator.
        Logger.warning(
          "#{__MODULE__}: inference failed: #{inspect(other) |> String.slice(0, 200)}"
        )

        []
    end
  end

  # `Net.forward/1` answers with a *list* of Mats, one per output layer,
  # even for a single-output model. Treating it as a Mat is the kind of
  # mistake that only shows up the first time real inference runs.
  defp first_output([%Evision.Mat{} = mat | _]), do: mat
  defp first_output(%Evision.Mat{} = mat), do: mat
  defp first_output(other), do: other

  defp mat_shape(mat) do
    case Evision.Mat.shape(mat) do
      {h, w} -> {h, w}
      {h, w, _channels} -> {h, w}
    end
  end

  @doc false
  # Split out and given its own tests: this is the part with no
  # accelerator, no model and no GPU involved, and the part most likely
  # to be silently wrong. A box that lands 20 pixels off looks
  # plausible on screen.
  def decode(flat, width, height, input_size, score_threshold, nms_threshold) do
    flat
    |> rows(input_size)
    |> Enum.flat_map(&best_class(&1, score_threshold))
    |> Enum.map(&to_pixels(&1, width, height, input_size))
    |> non_max_suppression(nms_threshold)
  end

  # yolov8 exports `[1, 4 + classes, anchors]` — attribute-major, so
  # every anchor's cx sits `anchors` apart from its cy, not next to it.
  # Reading it row-major is the classic way to get boxes that look
  # almost right.
  defp rows(flat, _input_size) do
    total = length(flat)
    attrs = 84
    anchors = div(total, attrs)

    if anchors == 0 or rem(total, attrs) != 0 do
      []
    else
      tensor = flat |> Nx.tensor() |> Nx.reshape({attrs, anchors})

      for a <- 0..(anchors - 1) do
        tensor[[.., a]] |> Nx.to_flat_list()
      end
    end
  end

  defp best_class([cx, cy, w, h | scores], threshold) do
    {score, class_id} =
      scores
      |> Enum.with_index()
      |> Enum.max_by(fn {s, _i} -> s end, fn -> {0.0, 0} end)

    if score >= threshold do
      [%{cx: cx, cy: cy, w: w, h: h, score: score, class_id: class_id}]
    else
      []
    end
  end

  defp best_class(_short_row, _threshold), do: []

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
