defmodule VisionApiWeb.CalibrationCase do
  @moduledoc """
  Test case with a stereo unit, the target `unit`, a camera of its own,
  the target `hq`, and their `VisionCore.Calibration.Session` running on
  `:vision_core` without cameras: the built-in calibrations in a
  temporary directory, the cameras' names registered, and solves and
  commits that answer at once, a pair's commit after `{:commit, pid}` is
  answered `:go`, a camera's telling `{:commit_camera, name}`.
  """
  use ExUnit.CaseTemplate

  alias VisionCore.Ros2.CameraCalibration

  using do
    quote do
      use VisionApiWeb.ConnCase, async: false

      @moduletag :capture_log
      @moduletag :tmp_dir

      import VisionApiWeb.CalibrationCase,
        only: [good_samples: 0, solved_result: 0, solved_camera_result: 0]
    end
  end

  # Names the cameras, which are idle processes.
  defmodule Camera do
    @moduledoc false
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @prefix "unit"

  setup %{tmp_dir: tmp_dir} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    File.mkdir_p!(tmp_dir)

    for side <- ["left", "right"] do
      File.write!(
        Path.join(tmp_dir, "#{@prefix}_#{side}.yaml"),
        CameraCalibration.to_yaml(calibration(), "#{@prefix}_#{side}")
      )
    end

    File.write!(Path.join(tmp_dir, "hq.yaml"), CameraCalibration.to_yaml(calibration(), "hq"))

    config = %VisionCore.Config{
      components: [
        stereo: [driver: Camera, prefix: @prefix, calibration_dir: tmp_dir, left: [], right: []],
        camera: [
          name: :hq,
          driver: Camera,
          calibration: Path.join(tmp_dir, "hq.yaml"),
          calibration_store_dir: Path.join(tmp_dir, "camera_store")
        ]
      ]
    }

    :persistent_term.put({VisionCore.Application, :active_config}, config)

    for label <- ["left", "right", "hq"] do
      camera = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(camera, Camera.name_for(label))
      on_exit(fn -> Process.exit(camera, :kill) end)
    end

    test_pid = self()

    start_supervised!(
      {VisionCore.Calibration.Session,
       config: config,
       solve: fn _board, _size, _samples -> {:ok, solved_result()} end,
       solve_camera: fn _board, _size, _views -> {:ok, solved_camera_result()} end,
       commit_camera: fn _config, name, _calibration ->
         send(test_pid, {:commit_camera, name})
         :ok
       end,
       commit: fn _config, _calibrations ->
         send(test_pid, {:commit, self()})

         receive do
           :go -> :ok
         end
       end}
    )

    %{config: config, prefix: @prefix}
  end

  @doc "A calibration of a 1280 x 720 camera."
  def calibration do
    %CameraCalibration{
      width: 1280,
      height: 720,
      distortion_model: "plumb_bob",
      distortion_coefficients: [0.1, -0.2, 0.0, 0.0, 0.0],
      camera_matrix: [900.0, 0.0, 640.0, 0.0, 910.0, 360.0, 0.0, 0.0, 1.0],
      rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
      projection_matrix: [880.0, 0.0, 640.0, 0.0, 0.0, 880.0, 360.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    }
  end

  @doc "What `VisionCore.Calibration.Solver.solve/3` answers."
  def solved_result do
    %{
      left: calibration(),
      right: calibration(),
      left_rms_px: 0.3,
      right_rms_px: 0.4,
      stereo_rms_px: 0.5,
      baseline_m: 0.12,
      fx_px: 900.0,
      samples: 40
    }
  end

  @doc "What `VisionCore.Calibration.Solver.solve_camera/3` answers."
  def solved_camera_result,
    do: %{camera: calibration(), rms_px: 0.2, fx_px: 880.0, samples: 40}

  @doc "Samples that cover enough views of the board, as either target keeps them."
  def good_samples do
    List.duplicate(
      %{
        views: %{"left" => [], "right" => [], "hq" => []},
        parameters: %{x: 0.5, y: 0.5, size: 0.2, skew: 0.1}
      },
      40
    )
  end
end
