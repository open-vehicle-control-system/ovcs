defmodule VisionCore.Detection.CameraSource do
  @moduledoc """
  Places the boxes of a `VisionCore.Detection.Pipeline` whose source is
  a camera of its own (`source: {:camera, name}` or `{:camera, name,
  output}`) with the camera's stereo depth,
  `VisionCore.Detection.CameraDepth`, which reads its calibration and
  pose once at start, keeps the stereo pairs to take the depth from and
  matches each frame with one.

  ## Placing a box

  The matched pair's depth is projected into the frame through the lens
  of the frame's size (`Reprojection.project/4`, every
  `:reprojection_stride`-th pixel and row), each box takes the median
  depth of the points inside its middle (`Fusion.projected_depths/3`)
  and is placed through the lens (`Fusion.unproject_camera/3`). A box
  without a distance, with no point inside it, no matched pair, no pose
  or no calibration, or 90° or more off-axis, is kept with `nil` `:x`,
  `:y`, `:z`, `:width`, `:height` and `:depth`. Each box has the
  `:bearing` of its centre, `{azimuth, elevation}` in radians in the
  camera's optical frame, azimuth positive to the right and elevation
  positive up (`Reprojection.bearing/2`), `nil` without a calibration
  or past the lens's fold.
  """
  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.{CameraDepth, Fusion, Reprojection}
  alias VisionCore.Stereo.Pair

  @doc """
  `detections`, boxes in `frame`'s pixels, placed with `pair`'s depth,
  `nil` for none, each sampled in its central `fraction` from every
  `stride`-th projected pixel (see the moduledoc), with their `:bearing`.
  Returns them with the camera's depth, which keeps the lens of
  `frame`'s size.
  """
  @spec place(CameraDepth.t(), [map()], Frame.t(), Pair.t() | nil, float(), pos_integer()) ::
          {[map()], CameraDepth.t()}
  def place(source, detections, %Frame{} = frame, pair, fraction, stride) do
    {lens, source} = CameraDepth.lens(source, {frame.width, frame.height})
    distances = distances(lens, source.pose, detections, pair, fraction, stride)

    placed =
      Enum.zip_with(detections, distances, fn detection, distance ->
        detection
        |> Map.merge(position(lens, detection, distance))
        |> Map.put(:bearing, bearing(lens, detection))
      end)

    {placed, source}
  end

  defp distances(lens, pose, detections, %Pair{depth: depth} = pair, fraction, stride)
       when not is_nil(lens) and not is_nil(pose) and is_binary(depth) do
    pair
    |> Reprojection.project(lens, pose, stride)
    |> Fusion.projected_depths(Enum.map(detections, & &1.box), fraction)
  end

  defp distances(_lens, _pose, detections, _pair, _fraction, _stride),
    do: Enum.map(detections, fn _detection -> nil end)

  defp position(lens, detection, distance) when is_float(distance) do
    case Fusion.unproject_camera(detection.box, distance, lens) do
      nil -> no_position()
      position -> Map.put(position, :depth, 0.1)
    end
  end

  defp position(_lens, _detection, nil), do: no_position()

  defp no_position, do: %{x: nil, y: nil, z: nil, width: nil, height: nil, depth: nil}

  defp bearing(nil, _detection), do: nil

  defp bearing(lens, %{box: box}),
    do: Reprojection.bearing(lens, {(box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2})

  @doc "The outline of `box` in the camera's pixels: its four corners, top-left first."
  @spec outline(map()) :: [{number(), number()}]
  def outline(box), do: [{box.x0, box.y0}, {box.x1, box.y0}, {box.x1, box.y1}, {box.x0, box.y1}]
end
