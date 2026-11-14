defmodule VisionCore.Calibration do
  @moduledoc """
  What the unit can calibrate: its stereo pair, identified by the stereo
  unit's prefix, each camera of its own that sends an image output,
  identified by its name, and, on a unit with a stereo pair, each such
  camera's pose relative to the pair, identified as `<name>-pose`. The
  dashboard reads the calibration in use of each target and returns it to
  its built-in one here; a `VisionCore.Calibration.Session` calibrates one
  of them.

  The stereo pair's files are `VisionCore.Stereo.Calibration`'s, a
  camera's `VisionCore.Camera.Calibration`'s, a pose's
  `VisionCore.Camera.Pose`'s.

  The unit keeps every calibration a target was given
  (`VisionCore.Calibration.Library`): `saved/2` lists them, `use_saved/3`
  puts one back in force, `rename_saved/3` names one and `delete_saved/3`
  removes one, the one in force once its target is back on its built-in
  calibration.
  """

  alias VisionCore.Calibration.{Library, Recorder, Saved, SavedCamera, SavedPose, Solver}
  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Camera.{Pose, Unit}
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Calibration, as: StereoCalibration
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @sides [:left, :right]
  @pose_left_label "left"

  @typedoc """
  A calibration target: its `id`, its `kind`, a camera's `name`, the
  labels of the frames its cameras send, the `VisionCore.Outputs` keys
  those frames are published under and the names its cameras register
  under. A pose's cameras are the camera, then the stereo left camera.
  """
  @type kind :: :stereo | :camera | :pose

  @type target :: %{
          id: String.t(),
          kind: kind(),
          name: atom() | nil,
          labels: [String.t()],
          frame_keys: [Outputs.key()],
          servers: [atom()]
        }

  @type camera :: %{
          name: String.t(),
          file: String.t(),
          path: Path.t() | nil,
          calibration: CameraCalibration.t() | nil,
          yaml: String.t() | nil
        }

  @typedoc "A pose in use: the pose, the file name to save its `yaml` under and its YAML."
  @type pose :: %{pose: Pose.t(), file: String.t(), yaml: String.t()}

  @typedoc """
  The calibration in use of a target: where it comes from, when a stored
  one was written, whether it can go back to a built-in one, each
  camera's calibration with the file name to save it under, for a
  stereo pair its rectified baseline, for a pose the pose, `nil` without
  one, and why a file gives no calibration, `nil` when each does or is
  absent. A pose's cameras are the stereo left camera's and the camera's
  calibrations in use, which it is measured with; its `source`,
  `stored_at`, `can_reset` and `error` are the pose's.
  """
  @type in_use :: %{
          id: String.t(),
          kind: kind(),
          source: :stored | :built_in | :none,
          stored_at: DateTime.t() | nil,
          can_reset: boolean(),
          cameras: [camera()],
          baseline_m: float() | nil,
          pose: pose() | nil,
          error: String.t() | nil
        }

  @doc """
  The targets of `config`, the active `VisionCore.Config`: its stereo
  pair first, then its cameras in config order, each followed by its pose
  on a unit with a stereo pair.
  """
  @spec targets(VisionCore.Config.t()) :: [target()]
  def targets(%VisionCore.Config{} = config) do
    stereo = stereo_targets(config)
    stereo ++ Enum.flat_map(camera_targets(config), &with_pose(&1, stereo))
  end

  @doc "The target `id` of `config`, or `:error`."
  @spec fetch_target(VisionCore.Config.t(), String.t()) :: {:ok, target()} | :error
  def fetch_target(config, id) do
    case Enum.find(targets(config), &(&1.id == id)) do
      nil -> :error
      target -> {:ok, target}
    end
  end

  @doc "The name the pose of the camera `name` is saved under, as it is installed in a vehicle package."
  @spec pose_file(atom()) :: String.t()
  def pose_file(name), do: "#{name}_pose.yaml"

  @doc "The `VisionCore.Outputs` key a change of `target`'s calibration is published under."
  @spec changed_key(target()) :: Outputs.key()
  def changed_key(%{kind: :stereo, id: prefix}), do: StereoCalibration.changed_key(prefix)
  def changed_key(%{kind: :camera, name: name}), do: OwnCalibration.changed_key(name)
  def changed_key(%{kind: :pose, name: name}), do: Pose.changed_key(name)

  @doc "The calibration in use of the target `id` of `config`; `{:error, :not_found}` for an id that is none of its targets."
  @spec in_use(VisionCore.Config.t(), String.t()) ::
          {:ok, in_use()} | {:error, :not_found | String.t()}
  def in_use(config, id) do
    with {:ok, target} <- fetch(config, id), do: target_in_use(config, target)
  end

  @doc """
  Returns the target `id` of `config` to its built-in calibration. `opts`
  are `VisionCore.Stereo.Calibration.reset/2`'s, for a stereo pair.
  """
  @spec reset(VisionCore.Config.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | String.t()}
  def reset(config, id, opts \\ []) do
    case fetch(config, id) do
      {:ok, %{kind: :stereo}} -> StereoCalibration.reset(config, opts)
      {:ok, %{kind: :camera, name: name}} -> OwnCalibration.reset(config, name)
      {:ok, %{kind: :pose, name: name}} -> Pose.reset(config, name)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  The calibrations a pose, the target `id` of `config`, is solved with:
  the stereo left camera's and the camera's, in force. `{:error,
  message}` naming the one that is missing, or that the solve does not
  take (`VisionCore.Calibration.Solver.check_pose_calibration/2`);
  `{:error, :not_found}` for an id that is no pose of `config`.
  """
  @spec pose_calibrations(VisionCore.Config.t(), String.t()) ::
          {:ok, %{left: CameraCalibration.t(), camera: CameraCalibration.t()}}
          | {:error, :not_found | String.t()}
  def pose_calibrations(config, id) do
    with {:ok, %{kind: :pose} = target} <- fetch(config, id),
         {:ok, %{cameras: [left, camera]}} <- target_in_use(config, target),
         :ok <-
           check_calibrated(left, "the stereo cameras have no calibration: calibrate them first"),
         :ok <-
           check_calibrated(
             camera,
             "the #{camera.name} camera has no calibration: calibrate it first"
           ),
         :ok <- Solver.check_pose_calibration(left.calibration, "the stereo cameras'"),
         :ok <- Solver.check_pose_calibration(camera.calibration, "the #{camera.name} camera's") do
      {:ok, %{left: left.calibration, camera: camera.calibration}}
    else
      {:ok, %{kind: _not_a_pose}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_calibrated(%{calibration: nil}, message), do: {:error, message}
  defp check_calibrated(_camera, _message), do: :ok

  @typedoc """
  A file of a calibration kept: its camera's `name`, the `file` name to
  save its `yaml` under, as for the calibration in use.
  """
  @type saved_file :: %{name: String.t(), file: String.t(), yaml: String.t()}

  @typedoc """
  A calibration kept, whether it is the one its target runs on, and its
  cameras' files, in the order of its cameras; a pose's file, for a pose.
  """
  @type kept :: %{saved: Saved.t(), in_force: boolean(), files: [saved_file()]}

  @doc "The calibrations kept for the target `id` of `config`, the one kept last first."
  @spec saved(VisionCore.Config.t(), String.t()) :: {:ok, [kept()]} | {:error, :not_found}
  def saved(config, id) do
    with {:ok, target} <- fetch(config, id) do
      selected = Library.selected(id)
      {:ok, Enum.map(Library.list(id), &kept(&1, target, selected))}
    end
  end

  @doc "The calibration `saved_id`, kept for a target of `config`."
  @spec fetch_saved(VisionCore.Config.t(), integer()) ::
          {:ok, kept()} | {:error, :not_found | String.t()}
  def fetch_saved(config, saved_id) do
    with {:ok, saved, target} <- saved_target(config, saved_id),
         do: {:ok, kept(saved, target, Library.selected(saved.target))}
  end

  @doc """
  Puts the calibration `saved_id` back in force: its figures are
  committed as its target's calibration. `opts` are
  `VisionCore.Stereo.Calibration.commit/3`'s, for a stereo pair.
  """
  @spec use_saved(VisionCore.Config.t(), integer(), keyword()) ::
          :ok | {:error, :not_found | String.t()}
  def use_saved(config, saved_id, opts \\ []) do
    with {:ok, saved, target} <- saved_target(config, saved_id) do
      figures = saved_figures(target, saved)
      expectation = Recorder.expect(target.id, figures, {:select, saved.id})
      answer = commit_figures(config, target, figures, opts)
      Recorder.forget(expectation)
      answer
    end
  end

  defp saved_figures(%{kind: :pose}, saved), do: SavedPose.to_pose(saved.pose)

  defp saved_figures(_target, saved),
    do: for(camera <- saved.cameras, do: {camera.name, SavedCamera.to_calibration(camera)})

  @doc "Names the calibration `saved_id`."
  @spec rename_saved(VisionCore.Config.t(), integer(), String.t()) ::
          {:ok, kept()} | {:error, :not_found | String.t()}
  def rename_saved(config, saved_id, name) do
    with {:ok, saved, target} <- saved_target(config, saved_id),
         {:ok, renamed} <- Library.rename(saved.id, name) do
      Recorder.changed(saved.target)
      {:ok, kept(renamed, target, Library.selected(saved.target))}
    end
  end

  @doc """
  Removes the calibration `saved_id`. When its target runs on it, the
  target first returns to its built-in calibration (`reset/3`, with
  `opts`): `{:error, :in_force}` when it has none to return to, and
  `{:error, {:reset, reason}}`, the calibration kept, when the return
  fails.
  """
  @spec delete_saved(VisionCore.Config.t(), integer(), keyword()) ::
          :ok | {:error, :not_found | :in_force | {:reset, String.t()} | String.t()}
  def delete_saved(config, saved_id, opts \\ []) do
    with {:ok, saved, target} <- saved_target(config, saved_id),
         :ok <- leave(config, saved, target, opts),
         :ok <- Library.delete(saved.id) do
      Recorder.changed(saved.target)
    end
  end

  # A target running on `saved` goes back to its built-in calibration, which has no selection.
  defp leave(config, saved, target, opts) do
    cond do
      not in_force?(saved, Library.selected(target.id)) -> :ok
      not resettable?(config, target) -> {:error, :in_force}
      true -> reset_to_built_in(config, target, opts)
    end
  end

  defp resettable?(config, target),
    do: match?({:ok, %{can_reset: true}}, target_in_use(config, target))

  defp reset_to_built_in(config, target, opts) do
    case reset(config, target.id, opts) do
      :ok -> Library.select(target.id, nil)
      {:error, reason} -> {:error, {:reset, reason}}
    end
  end

  defp kept(saved, target, selected),
    do: %{saved: saved, in_force: in_force?(saved, selected), files: files(saved, target)}

  defp in_force?(saved, selected), do: selected != nil and selected.id == saved.id

  defp files(%{pose: %SavedPose{} = pose}, %{kind: :pose, name: name}) do
    yaml = pose |> SavedPose.to_pose() |> Pose.to_yaml()
    [%{name: Atom.to_string(name), file: pose_file(name), yaml: yaml}]
  end

  defp files(saved, target) do
    for camera <- saved.cameras do
      stem = file_stem(target, camera.name)

      %{
        name: camera.name,
        file: "#{stem}.yaml",
        yaml: CameraCalibration.to_yaml(SavedCamera.to_calibration(camera), stem)
      }
    end
  end

  # The name, without its extension, a camera's file is saved under: `<prefix>_<side>` for a pair's side.
  defp file_stem(%{kind: :stereo, id: prefix}, side), do: "#{prefix}_#{side}"
  defp file_stem(%{kind: :camera, id: id}, _name), do: id

  # A calibration kept for a target the unit no longer has is not found.
  defp saved_target(config, saved_id) do
    with {:ok, saved} <- Library.fetch(saved_id),
         {:ok, target} <- fetch(config, saved.target) do
      {:ok, saved, target}
    end
  end

  defp commit_figures(config, %{kind: :stereo}, cameras, opts) do
    calibrations =
      Map.new(cameras, fn {side, calibration} -> {String.to_existing_atom(side), calibration} end)

    StereoCalibration.commit(config, calibrations, opts)
  end

  defp commit_figures(config, %{kind: :camera, name: name}, [{_name, calibration}], _opts),
    do: OwnCalibration.commit(config, name, calibration)

  defp commit_figures(config, %{kind: :pose, name: name}, %Pose{} = pose, _opts),
    do: Pose.commit(config, name, pose)

  defp fetch(config, id) do
    case fetch_target(config, id) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :not_found}
    end
  end

  defp stereo_targets(config) do
    case StereoSupervisor.camera_options(config) do
      {:ok, cameras} ->
        [
          %{
            id: cameras[:prefix],
            kind: :stereo,
            name: nil,
            labels: Enum.map(@sides, &Atom.to_string/1),
            frame_keys:
              for({{:camera_frame, _side}, key} <- StereoSupervisor.outputs(config), do: key),
            servers: for({_driver, server} <- StereoSupervisor.cameras(config), do: server)
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  # The camera's pose relative to the pair: its frames first, whose image the coverage is measured in.
  defp with_pose(camera, []), do: [camera]

  defp with_pose(camera, [%{frame_keys: [left_key, _right_key], servers: [left_server, _right]}]) do
    pose = %{
      camera
      | id: "#{camera.id}-pose",
        kind: :pose,
        labels: camera.labels ++ [@pose_left_label],
        frame_keys: camera.frame_keys ++ [left_key],
        servers: camera.servers ++ [left_server]
    }

    [camera, pose]
  end

  defp camera_targets(config) do
    for settings <- Unit.settings(config),
        key = Unit.output_key(config, settings.name, nil) do
      label = Atom.to_string(settings.name)

      %{
        id: label,
        kind: :camera,
        name: settings.name,
        labels: [label],
        frame_keys: [key],
        servers: [settings.server]
      }
    end
  end

  defp target_in_use(config, %{kind: :stereo, id: prefix}) do
    with {:ok, in_use} <- StereoCalibration.in_use(config) do
      cameras =
        for side <- @sides,
            do: camera(Atom.to_string(side), "#{prefix}_#{side}.yaml", in_use[side])

      {:ok,
       %{
         id: prefix,
         kind: :stereo,
         source: in_use.source,
         stored_at: in_use.stored_at,
         can_reset: in_use.can_reset,
         cameras: cameras,
         baseline_m: in_use.baseline_m,
         pose: nil,
         error: in_use.error
       }}
    end
  end

  defp target_in_use(config, %{kind: :camera, id: id, name: name}) do
    with {:ok, in_use} <- OwnCalibration.in_use(config, name) do
      {:ok,
       %{
         id: id,
         kind: :camera,
         source: in_use.source,
         stored_at: in_use.stored_at,
         can_reset: in_use.can_reset,
         cameras: [camera(id, "#{id}.yaml", in_use.camera)],
         baseline_m: nil,
         pose: nil,
         error: in_use.error
       }}
    end
  end

  defp target_in_use(config, %{kind: :pose, id: id, name: name}) do
    label = Atom.to_string(name)

    with {:ok, pair} <- StereoCalibration.in_use(config),
         {:ok, own} <- OwnCalibration.in_use(config, name),
         {:ok, in_use} <- Pose.in_use(config, name) do
      {:ok,
       %{
         id: id,
         kind: :pose,
         source: in_use.source,
         stored_at: in_use.stored_at,
         can_reset: in_use.can_reset,
         cameras: [
           camera(@pose_left_label, "#{pair.prefix}_left.yaml", pair.left),
           camera(label, "#{label}.yaml", own.camera)
         ],
         baseline_m: nil,
         pose: pose_in_use(in_use, name),
         error: in_use.error
       }}
    end
  end

  defp pose_in_use(%{pose: nil}, _name), do: nil

  defp pose_in_use(%{pose: pose, yaml: yaml}, name),
    do: %{pose: pose, file: pose_file(name), yaml: yaml}

  defp camera(name, file, %{path: path, calibration: calibration, yaml: yaml}),
    do: %{name: name, file: file, path: path, calibration: calibration, yaml: yaml}
end
