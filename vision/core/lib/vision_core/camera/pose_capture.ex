defmodule VisionCore.Camera.PoseCapture do
  @moduledoc """
  Records the image pairs `scripts/camera_pose.py` measures a camera's
  pose from (`VisionCore.Camera.Pose`): the stereo left camera's raw
  frame and the frame of a camera of its own (`VisionCore.Camera.Unit`)
  captured closest to it in time, within half a stereo pair period.

  Called from the unit's IEx shell, once per pose of the chessboard,
  while the board is held still:

      VisionCore.Camera.PoseCapture.capture(:hq)

  It listens to both cameras' frames (`VisionCore.Outputs`) until it
  finds such a pair, writes it as `left-<n>` and `camera-<n>`, numbered
  after the pairs already there, and stops listening. A grey or RGB
  frame is written as PNG, a JPEG frame as it is.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Debug.Png
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @default_directory "/data/vision/pose_pairs"
  @default_timeout_ms 5_000
  # Frames of each camera kept to match the other's against.
  @frames_kept 4

  @typedoc "The pair written: its two files and how far apart their captures are."
  @type saved :: %{left: Path.t(), camera: Path.t(), offset_ms: float()}

  @doc """
  Writes the next pair of the stereo left camera and the camera `name`.

  Options:

    * `:directory` (`#{@default_directory}/<name>`) — where the pair
      is written, created when missing.
    * `:timeout_ms` (#{@default_timeout_ms}) — how long to wait for a
      pair.
    * `:output` (the camera's default) — the camera's output whose
      frames are written (`VisionCore.Camera.Output`).
    * `:config` (the active `VisionCore.Config`) — the unit's
      configuration.

  `{:error, :no_matching_pair}` when no two frames came within half a
  pair period of each other in time; `{:error, {:no_camera, name}}` or
  `{:error, :no_stereo_unit}` when the configuration has no such camera,
  or no such output of it, or no stereo unit.
  """
  @spec capture(atom(), keyword()) :: {:ok, saved()} | {:error, term()}
  def capture(name, options \\ []) do
    options =
      Keyword.validate!(options, [
        :config,
        :output,
        directory: Path.join(@default_directory, Atom.to_string(name)),
        timeout_ms: @default_timeout_ms
      ])

    config = options[:config] || VisionCore.Application.active_config()

    with {:ok, keys, tolerance_ns} <- sources(config, name, options[:output]),
         {:ok, left, camera} <- next_pair(keys, tolerance_ns, options[:timeout_ms]) do
      write_pair(left, camera, options[:directory])
    end
  end

  defp sources(config, name, output) do
    with {:ok, stereo} <- stereo_cameras(config),
         camera_key when camera_key != nil <-
           VisionCore.Exporter.output_key(camera_output(name, output), config) do
      left_key = VisionCore.Exporter.output_key({:camera_frame, :left}, config)
      {:ok, {left_key, camera_key}, div(1_000_000_000, stereo[:fps] * 2)}
    else
      nil -> {:error, {:no_camera, name}}
      {:error, :no_stereo_unit} -> {:error, :no_stereo_unit}
    end
  end

  defp camera_output(name, nil), do: {:camera_frame, name}
  defp camera_output(name, output), do: {:camera_frame, name, output}

  defp stereo_cameras(config) do
    case StereoSupervisor.camera_options(config) do
      {:ok, cameras} -> {:ok, cameras}
      {:error, _reason} -> {:error, :no_stereo_unit}
    end
  end

  defp next_pair({left_key, camera_key} = keys, tolerance_ns, timeout_ms) do
    :ok = VisionCore.Outputs.subscribe(left_key)
    :ok = VisionCore.Outputs.subscribe(camera_key)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      await_pair(%{left: [], camera: []}, tolerance_ns, deadline)
    after
      Enum.each(Tuple.to_list(keys), &VisionCore.Outputs.unsubscribe/1)
      flush_frames()
    end
  end

  defp await_pair(frames, tolerance_ns, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:"$gen_cast", {:camera_frame, %Frame{label: "left"} = frame}} ->
        match(frame, :left, frames, tolerance_ns, deadline)

      {:"$gen_cast", {:camera_frame, %Frame{} = frame}} ->
        match(frame, :camera, frames, tolerance_ns, deadline)
    after
      remaining_ms -> {:error, :no_matching_pair}
    end
  end

  defp match(frame, side, frames, tolerance_ns, deadline) do
    other_side = if side == :left, do: :camera, else: :left

    closest =
      frames[other_side]
      |> Enum.filter(&(abs(&1.capture_ns - frame.capture_ns) <= tolerance_ns))
      |> Enum.min_by(&abs(&1.capture_ns - frame.capture_ns), fn -> nil end)

    case {side, closest} do
      {_side, nil} ->
        frames = Map.update!(frames, side, &Enum.take([frame | &1], @frames_kept))
        await_pair(frames, tolerance_ns, deadline)

      {:left, camera} ->
        {:ok, frame, camera}

      {:camera, left} ->
        {:ok, left, frame}
    end
  end

  defp flush_frames do
    receive do
      {:"$gen_cast", {:camera_frame, _frame}} -> flush_frames()
    after
      0 -> :ok
    end
  end

  defp write_pair(left, camera, directory) do
    File.mkdir_p!(directory)
    number = directory |> next_number() |> Integer.to_string() |> String.pad_leading(4, "0")
    left_path = write_frame(left, Path.join(directory, "left-#{number}"))
    camera_path = write_frame(camera, Path.join(directory, "camera-#{number}"))

    {:ok,
     %{
       left: left_path,
       camera: camera_path,
       offset_ms: abs(camera.capture_ns - left.capture_ns) / 1_000_000
     }}
  end

  defp next_number(directory) do
    directory
    |> File.ls!()
    |> Enum.flat_map(fn file ->
      case Regex.run(~r/^left-(\d+)\./, file) do
        [_file, number] -> [String.to_integer(number) + 1]
        nil -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp write_frame(%Frame{jpeg: jpeg}, path) when is_binary(jpeg),
    do: write(path <> ".jpg", jpeg)

  defp write_frame(%Frame{grey: grey, width: width, height: height}, path) when is_binary(grey),
    do: write(path <> ".png", Png.grey(grey, width, height))

  defp write_frame(%Frame{rgb: rgb, width: width, height: height}, path) when is_binary(rgb),
    do: write(path <> ".png", Png.rgb(rgb, width, height))

  defp write(path, bytes) do
    File.write!(path, bytes)
    path
  end
end
