defmodule RosBridge.Camera.Calibration do
  @moduledoc """
  ROS-format camera calibration loaded from a
  `camera_calibration_parsers` YAML — the same format
  `cameracalibrator` writes (`left.yaml` / `right.yaml`).

  We carry the raw flat-list representation of each matrix
  (row-major, as the YAML provides them); converting to Nx
  tensors or Evision Mats is the consumer's responsibility.
  Two consumers today:

    * `RosBridge.Publishers.Camera` — populates the outgoing
      `sensor_msgs/CameraInfo` directly from these fields.
    * `RosBridge.StereoCamera.OpenCV` — builds undistortion +
      rectification look-up tables via
      `Evision.initUndistortRectifyMap/6`.

  ## YAML schema we accept

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

  We use regex-driven parsing (rather than pulling in a full
  YAML parser) because the field set is small, fixed, and the
  format is well-defined. If a future calibrator produces
  exotic formatting we fail loudly via `load!/1`.
  """

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

  @empty_3x3 [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  @empty_3x4 [
    0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0
  ]

  @doc """
  Load a calibration YAML. Returns `{:ok, %Calibration{}}` or
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
      distortion_model:
        read_string(yaml, ~r/^distortion_model:\s*"?([^"\n]+)"?/m, "plumb_bob"),
      distortion_coefficients:
        read_matrix(
          yaml,
          ~r/^distortion_coefficients:.*?data:\s*\[([^\]]*)\]/ms,
          []
        ),
      camera_matrix:
        read_matrix(yaml, ~r/^camera_matrix:.*?data:\s*\[([^\]]*)\]/ms, @empty_3x3),
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

  # ── regex helpers ────────────────────────────────────────────

  defp read_integer(yaml, regex, default) do
    case Regex.run(regex, yaml) do
      [_, value] -> String.to_integer(value)
      _ -> default
    end
  end

  defp read_string(yaml, regex, default) do
    case Regex.run(regex, yaml) do
      [_, value] -> String.trim(value)
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

  defp parse_float(text) do
    if String.contains?(text, ".") or String.contains?(text, "e") or
         String.contains?(text, "E") do
      String.to_float(text)
    else
      String.to_float(text <> ".0")
    end
  end
end
