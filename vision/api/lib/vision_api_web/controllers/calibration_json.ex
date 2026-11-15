defmodule VisionApiWeb.CalibrationJSON do
  @moduledoc """
  A calibration in use, as a `calibrations` JSON:API resource and as
  the `calibration` channel carries it.

  A calibration has its `kind`, `stereo`, `camera` or `pose`, its
  `source` (`builtIn`, `stored` or `none`), `storedAt`, `canReset`, its
  `cameras`, each with its `name`, the `file` to save its `yaml` under,
  its image size, intrinsics and distortion, for a stereo pair
  `baselineM` and `rectifiedFx`, `null` otherwise, for a pose its `pose`
  (`VisionApiWeb.CalibrationPose`), `null` otherwise or without one,
  and its `error`, why a file gives no calibration. A pose's cameras
  are the stereo left camera's and the camera's calibrations it is
  measured with.
  """
  alias VisionApiWeb.{CalibrationPose, JsonApi}

  @doc "The `calibrations` resources of `calibrations`, each from `VisionCore.Calibration.in_use/2`."
  @spec index(%{calibrations: [VisionCore.Calibration.in_use()]}) :: map()
  def index(%{calibrations: calibrations}), do: %{data: Enum.map(calibrations, &data/1)}

  @doc "The `calibrations` resource of `in_use`."
  @spec show(%{in_use: VisionCore.Calibration.in_use()}) :: map()
  def show(%{in_use: in_use}), do: %{data: data(in_use)}

  defp data(in_use), do: JsonApi.resource("calibrations", in_use.id, in_use(in_use))

  @doc "The attributes of a calibration in use."
  @spec in_use(VisionCore.Calibration.in_use()) :: map()
  def in_use(in_use) do
    %{
      kind: Atom.to_string(in_use.kind),
      source: source(in_use.source),
      storedAt: in_use.stored_at && DateTime.to_iso8601(in_use.stored_at),
      canReset: in_use.can_reset,
      error: in_use.error,
      baselineM: in_use.baseline_m,
      rectifiedFx: rectified_fx(in_use),
      cameras: Enum.map(in_use.cameras, &camera/1),
      pose: pose_in_use(in_use.pose)
    }
  end

  defp pose_in_use(nil), do: nil

  defp pose_in_use(%{pose: pose, file: file, yaml: yaml}),
    do: CalibrationPose.attributes(pose, file, yaml)

  defp source(:built_in), do: "builtIn"
  defp source(source), do: Atom.to_string(source)

  defp camera(%{calibration: nil} = camera),
    do: %{
      name: camera.name,
      file: camera.file,
      imageWidth: nil,
      imageHeight: nil,
      fx: nil,
      fy: nil,
      cx: nil,
      cy: nil,
      distortion: nil,
      yaml: camera.yaml
    }

  defp camera(%{calibration: calibration} = camera) do
    [fx, _, cx, _, fy, cy | _rest] = calibration.camera_matrix

    %{
      name: camera.name,
      file: camera.file,
      imageWidth: calibration.width,
      imageHeight: calibration.height,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      distortion: calibration.distortion_coefficients,
      yaml: camera.yaml
    }
  end

  # The left camera's rectified focal length, the one a pair's solve gives as `fx_px`.
  defp rectified_fx(%{kind: :stereo, cameras: [%{calibration: %{} = left} | _right]}),
    do: hd(left.projection_matrix)

  defp rectified_fx(_in_use), do: nil
end
