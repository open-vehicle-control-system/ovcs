defmodule VisionCore.Ros2.CameraCalibration do
  @moduledoc """
  ROS-format camera calibration loaded from a
  `camera_calibration_parsers` YAML — the same format
  `cameracalibrator` writes (`left.yaml` / `right.yaml`).

  Each matrix is kept as the YAML's flat row-major list; converting to Nx
  tensors is the consumer's responsibility. Two consumers:

    * `VisionCore.Ros2.Exporter.Stereo` — populates the outgoing
      `sensor_msgs/CameraInfo` directly from these fields.
    * `VisionCore.Stereo.Stage.Rectification` — undistorts and rectifies with
      `NxStereo.Rectify`.

  ## Accepted YAML schema

      image_width: <int>
      image_height: <int>
      distortion_model: plumb_bob
      distortion_coefficients:
        data: [d0, d1, ...]
      camera_matrix:
        data: [fx, 0, cx, 0, fy, cy, 0, 0, 1]
      rectification_matrix:
        data: [r0, ..., r8]
      projection_matrix:
        data: [P00, P01, P02, P03, P10, ..., P23]

  Parsing is regex-driven rather than a full YAML parser because the
  field set is small, fixed, and the format is well-defined.

  ## Numbers

  Every numeric spelling the calibration tools emit is accepted, which
  `String.to_float/1` is too strict for; `load!/1` runs inside
  `VisionCore.Stereo.Pipeline.init/1`, and a calibration it cannot read
  leaves the stereo unit down:

    * `"0."` / `"1."` — cameracalibrator writes whole numbers with a
      bare trailing dot, which `Float.parse/1` leaves as a `"."`
      remainder.
    * `"1e-3"` — an exponent with no decimal point in the mantissa;
      Erlang rejects it, `Float.parse/1` accepts it.
    * `".5"` — a leading dot, which `Float.parse/1` rejects, is padded
      with a zero first.
  """

  alias Ros2Zenoh.SensorMsgs.Msg.CameraInfo

  defstruct [
    :width,
    :height,
    :distortion_model,
    :distortion_coefficients,
    :camera_matrix,
    :rectification_matrix,
    :projection_matrix
  ]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          distortion_model: String.t(),
          distortion_coefficients: [float()],
          camera_matrix: [float()],
          rectification_matrix: [float()],
          projection_matrix: [float()]
        }

  @aspect_tolerance 0.01
  @empty_3x3 [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  # Written as rows and flattened: `mix format` puts a flat 12-element
  # list one element per line, which loses the 3x4 shape entirely.
  @empty_3x4 List.flatten([
               [0.0, 0.0, 0.0, 0.0],
               [0.0, 0.0, 0.0, 0.0],
               [0.0, 0.0, 0.0, 0.0]
             ])

  @doc """
  Load a calibration YAML. Returns `{:ok, %CameraCalibration{}}` or
  `{:error, reason}` if the file is unreadable. Missing fields
  inside the YAML are populated with sensible defaults
  (zero-matrices, `"plumb_bob"`, etc.).
  """
  @spec load(Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(nil), do: {:error, :no_path}

  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, yaml} -> {:ok, parse(yaml)}
      error -> error
    end
  end

  @doc """
  Same as `load/1` but raises on read failure. Use from
  `init/1` callbacks where a missing calibration file should
  fail the boot.
  """
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, calibration} ->
        calibration

      {:error, reason} ->
        raise "#{inspect(__MODULE__)}: cannot read calibration #{inspect(path)}: " <>
                inspect(reason)
    end
  end

  @doc """
  Parse a YAML body directly (no file I/O). Each missing field
  falls back to a zero-matrix / `"plumb_bob"` default — the
  caller can detect "no calibration" by checking that the
  matrices are all zero.
  """
  @spec parse(String.t()) :: t()
  def parse(yaml) when is_binary(yaml) do
    %__MODULE__{
      width: read_integer(yaml, ~r/^image_width:\s*(\d+)/m, 0),
      height: read_integer(yaml, ~r/^image_height:\s*(\d+)/m, 0),
      distortion_model: read_string(yaml, ~r/^distortion_model:\s*"?([^"\n]+)"?/m, "plumb_bob"),
      distortion_coefficients:
        read_matrix(
          yaml,
          ~r/^distortion_coefficients:.*?data:\s*\[([^\]]*)\]/ms,
          []
        ),
      camera_matrix: read_matrix(yaml, ~r/^camera_matrix:.*?data:\s*\[([^\]]*)\]/ms, @empty_3x3),
      rectification_matrix:
        read_matrix(
          yaml,
          ~r/^rectification_matrix:.*?data:\s*\[([^\]]*)\]/ms,
          @empty_3x3
        ),
      projection_matrix:
        read_matrix(yaml, ~r/^projection_matrix:.*?data:\s*\[([^\]]*)\]/ms, @empty_3x4)
    }
  end

  defp read_integer(yaml, regex, default) do
    case Regex.run(regex, yaml) do
      [_, digits] -> String.to_integer(digits)
      _ -> default
    end
  end

  defp read_string(yaml, regex, default) do
    case Regex.run(regex, yaml) do
      [_, text] -> String.trim(text)
      _ -> default
    end
  end

  defp read_matrix(yaml, regex, default) do
    case Regex.run(regex, yaml) do
      [_, body] ->
        body
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_float/1)

      _ ->
        default
    end
  end

  # See "Numbers" in the moduledoc for the spellings accepted.
  defp parse_float(text) do
    text = text |> String.trim() |> pad_leading_zero()

    case Float.parse(text) do
      {number, rest} when rest in ["", "."] ->
        number

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}: cannot parse #{inspect(text)} as a float"
    end
  end

  defp pad_leading_zero("." <> _ = text), do: "0" <> text
  defp pad_leading_zero("-." <> rest), do: "-0." <> rest
  defp pad_leading_zero(text), do: text

  @doc """
  Rescale a calibration saved at one resolution to the resolution the
  cameras are actually running at.

  Pixel-indexed intrinsics scale linearly: a 0.5x resize halves fx,
  fy, cx, cy and every pixel-space term of `P`. The physical baseline
  encoded in `P_right[0,3] = -fx x T` survives because `P[0,3]` and
  `P[0,0]` scale by the same factor. Distortion coefficients `D` and
  the rectification rotation `R` are resolution-invariant.

  Only valid for a proportional resize (`proportional?/3`). Changing the
  *aspect* ratio changes which part of the sensor is sampled and needs a
  fresh calibration, not a rescale.

  The principal point scales with the pixel's corner as origin: `cx`
  becomes `cx × s`, `s` the new width over the saved one. Rectification
  (`NxStereo.Rectify` and the `stereo_match` Port) maps pixel centres
  instead: a working pixel `x` samples the frame at `(x + 0.5) / s − 0.5`.
  Against that convention a scaled principal point sits `(1 − s) / 2`
  new pixels off: under half a pixel when shrinking.
  """
  @spec scale_to(t(), pos_integer(), pos_integer()) :: t()
  def scale_to(%__MODULE__{} = calibration, actual_width, actual_height)
      when actual_width > 0 and actual_height > 0 do
    cond do
      calibration.width == 0 or calibration.height == 0 ->
        # No reference dimensions in the YAML — trust the intrinsics as-is.
        %{calibration | width: actual_width, height: actual_height}

      calibration.width == actual_width and calibration.height == actual_height ->
        calibration

      true ->
        scale_x = actual_width / calibration.width
        scale_y = actual_height / calibration.height

        %{
          calibration
          | width: actual_width,
            height: actual_height,
            camera_matrix: scale_3x3(calibration.camera_matrix, scale_x, scale_y),
            projection_matrix: scale_3x4(calibration.projection_matrix, scale_x, scale_y)
        }
    end
  end

  @doc """
  The calibration of the image resampled to `width × height` over the
  same field of view, pixel centres mapped onto pixel centres: a
  coordinate `u` becomes `(u + ½) × s − ½`, `s` the new width over the
  saved one, and likewise `v`. Exact for a camera's output averaged in
  blocks from another (`VisionCore.Camera.Output`), where 2 × 2 gives
  `fx / 2` and `(cx + ½) / 2 − ½`, and for an output made at another
  size from the same sensor area. `D` and `R` stay. A calibration
  without a size is taken as it is, as by `scale_to/3`. Only valid for
  a proportional resize (`proportional?/3`).
  """
  @spec resample_to(t(), pos_integer(), pos_integer()) :: t()
  def resample_to(%__MODULE__{} = calibration, width, height) when width > 0 and height > 0 do
    cond do
      calibration.width == 0 or calibration.height == 0 ->
        %{calibration | width: width, height: height}

      calibration.width == width and calibration.height == height ->
        calibration

      true ->
        scale_x = width / calibration.width
        scale_y = height / calibration.height
        to_centres = {{scale_x, (scale_x - 1) / 2}, {scale_y, (scale_y - 1) / 2}}

        %{
          calibration
          | width: width,
            height: height,
            camera_matrix: map_rows(calibration.camera_matrix, 3, to_centres),
            projection_matrix: map_rows(calibration.projection_matrix, 4, to_centres)
        }
    end
  end

  # The first two rows times their scale, plus the last row times their offset.
  defp map_rows(matrix, columns, {{scale_x, offset_x}, {scale_y, offset_y}}) do
    [row_x, row_y, last] = Enum.chunk_every(matrix, columns)

    Enum.zip_with(row_x, last, &(&1 * scale_x + &2 * offset_x)) ++
      Enum.zip_with(row_y, last, &(&1 * scale_y + &2 * offset_y)) ++ last
  end

  @doc """
  Whether `scale_to/3` can take `calibration` to `width × height`: the
  two aspect ratios are within 1 % of each other, or the calibration has
  no size.
  """
  @spec proportional?(t(), pos_integer(), pos_integer()) :: boolean()
  def proportional?(%__MODULE__{width: saved_width, height: saved_height}, width, height)
      when saved_width > 0 and saved_height > 0,
      do: abs(width * saved_height / (height * saved_width) - 1) <= @aspect_tolerance

  def proportional?(%__MODULE__{}, _width, _height), do: true

  defp scale_3x3([r0c0, r0c1, r0c2, r1c0, r1c1, r1c2, r2c0, r2c1, r2c2], scale_x, scale_y) do
    [
      r0c0 * scale_x,
      r0c1 * scale_x,
      r0c2 * scale_x,
      r1c0 * scale_y,
      r1c1 * scale_y,
      r1c2 * scale_y,
      r2c0,
      r2c1,
      r2c2
    ]
  end

  defp scale_3x4(
         [r0c0, r0c1, r0c2, r0c3, r1c0, r1c1, r1c2, r1c3, r2c0, r2c1, r2c2, r2c3],
         scale_x,
         scale_y
       ) do
    [
      r0c0 * scale_x,
      r0c1 * scale_x,
      r0c2 * scale_x,
      r0c3 * scale_x,
      r1c0 * scale_y,
      r1c1 * scale_y,
      r1c2 * scale_y,
      r1c3 * scale_y,
      r2c0,
      r2c1,
      r2c2,
      r2c3
    ]
  end

  @doc """
  Render a calibration to the `camera_calibration_parsers` YAML
  shape that the vision core already loads from. Used to persist a
  `sensor_msgs/CameraInfo` received via the
  `set_camera_info` service onto disk so the next boot picks it
  up automatically.

  `camera_name` is the YAML's `camera_name:` field — informational
  only; loads ignore it. The matrices are flat row-major lists
  matching the struct's representation.
  """
  @spec to_yaml(t(), String.t()) :: String.t()
  def to_yaml(%__MODULE__{} = calibration, camera_name) do
    """
    image_width: #{calibration.width}
    image_height: #{calibration.height}
    camera_name: #{camera_name}
    camera_matrix:
      rows: 3
      cols: 3
      data: [#{format_floats(calibration.camera_matrix)}]
    distortion_model: #{calibration.distortion_model}
    distortion_coefficients:
      rows: 1
      cols: #{length(calibration.distortion_coefficients)}
      data: [#{format_floats(calibration.distortion_coefficients)}]
    rectification_matrix:
      rows: 3
      cols: 3
      data: [#{format_floats(calibration.rectification_matrix)}]
    projection_matrix:
      rows: 3
      cols: 4
      data: [#{format_floats(calibration.projection_matrix)}]
    """
  end

  @doc """
  `calibration`'s `sensor_msgs/CameraInfo` for a `width` x `height`
  image under `header`, with the camera matrix `camera_matrix`, the
  calibration's own unless the image is a part of the camera's: its
  distortion, no rectification, and the projection matrix the camera
  matrix padded with a zero column.
  """
  @spec camera_info(t(), struct(), pos_integer(), pos_integer(), [float()]) :: CameraInfo.t()
  def camera_info(calibration, header, width, height, camera_matrix \\ nil) do
    [k0, k1, k2, k3, k4, k5, k6, k7, k8] = k = camera_matrix || calibration.camera_matrix

    %CameraInfo{
      header: header,
      width: width,
      height: height,
      distortion_model: calibration.distortion_model,
      d: calibration.distortion_coefficients,
      k: k,
      r: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      p: [k0, k1, k2, 0.0, k3, k4, k5, 0.0, k6, k7, k8, 0.0]
    }
  end

  @doc """
  Build a `Calibration` struct from a `sensor_msgs/CameraInfo`
  parsed off the wire. The CameraInfo carries the same matrices
  (k, r, p, d) but with different field names — this is a pure
  rename.
  """
  @spec from_camera_info(CameraInfo.t()) :: t()
  def from_camera_info(%CameraInfo{} = camera_info) do
    %__MODULE__{
      width: camera_info.width,
      height: camera_info.height,
      distortion_model: camera_info.distortion_model,
      distortion_coefficients: camera_info.d,
      camera_matrix: camera_info.k,
      rectification_matrix: camera_info.r,
      projection_matrix: camera_info.p
    }
  end

  defp format_floats(values) do
    Enum.map_join(values, ", ", &format_float/1)
  end

  defp format_float(number) when is_float(number), do: Float.to_string(number)
  defp format_float(number) when is_integer(number), do: Float.to_string(number * 1.0)
end
