defmodule VisionCore.Stereo.Calibration do
  @moduledoc """
  Reads and writes the stereo unit's calibration files, for the
  dashboard. `cameracalibrator`'s COMMIT writes them one side at a time,
  through `VisionCore.Ros2.Services.SetCameraInfoServer`.

  The unit's options resolve where each side's calibration is
  (`VisionCore.Stereo.Supervisor.camera_options/1`): with a
  `:calibration_store_dir`, a calibration committed goes to the store
  and, once both sides are stored, is the one in force; the
  `:calibration_dir` or the side's `:calibration_path` holds the built-in
  one, which `reset/2` goes back to. Without a store, a commit writes the
  calibration paths themselves.

  A commit writes the files, then has the stereo unit reload them. Each
  file is written whole or not at all, through a temporary file renamed
  over it; every temporary file is written before the first rename, so
  that the renames follow each other. When the unit refuses them, the
  files go back to what they held, or are removed when there was none,
  and the answer is `{:error, reason}`. When the reload raises or exits,
  as one that does not answer in time, the unit may have taken them all
  the same: the files go back, and the unit reloads the calibration then
  in force.
  Each commit or reset the unit takes is published as
  `{:stereo_calibration_changed, prefix}` under `changed_key/1`. The
  commits and resets of one unit made here run one at a time; the ROS 2
  service does not wait for them.

  A unit whose pipeline is not running, as an uncalibrated one that runs
  its cameras alone or one that gave up, is restarted instead, so that it
  starts with its pipeline on the files written. The saved
  `right_row_offset` is forgotten first
  (`VisionCore.Stereo.Supervisor.forget_row_offset/1`). When the unit
  does not start, or the forget or the restart raises or exits, the
  files go back as on a refused reload, and the unit is restarted on
  them, its cameras running again.

  ## Options

    * `:reload` — called with the calibration paths to reload, as
      `[left_calibration_path: path, right_calibration_path: path]`,
      answering `:ok` once the unit has taken them. By default
      `VisionCore.Stereo.Supervisor.reload_calibration/3` on
      `VisionCore.Stereo.Pipeline`.
    * `:restart` — called with no argument to restart the unit,
      answering `{:ok, pid}` once it runs, as `Supervisor.restart_child/2`
      does. By default the `VisionCore.Stereo.Supervisor` child of
      `VisionCore.Supervisor` is terminated and restarted.
    * `:pipeline_running?` — called with no argument, whether the unit's
      pipeline runs to reload the files. By default whether
      `VisionCore.Stereo.Pipeline` is registered.
  """
  require Logger

  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @sides [:left, :right]

  @type side :: %{
          path: String.t() | nil,
          calibration: CameraCalibration.t() | nil,
          yaml: String.t() | nil
        }

  @type in_use :: %{
          source: :stored | :built_in | :none,
          stored_at: DateTime.t() | nil,
          can_reset: boolean(),
          prefix: String.t(),
          left: side(),
          right: side(),
          baseline_m: float() | nil,
          error: String.t() | nil
        }

  @doc "The `VisionCore.Outputs` key a change of the calibration of the unit `prefix` is published under."
  @spec changed_key(String.t()) :: {:stereo_calibration, String.t()}
  def changed_key(prefix), do: {:stereo_calibration, prefix}

  @doc """
  The calibration in force for the stereo unit of `config`, the active
  `VisionCore.Config`: per side its path, parsed calibration and YAML
  (`nil` without a file), and its source. `stored_at` is the time the
  later of the stored files was written, and `can_reset` whether
  anything is stored, a side stored alone included, with a built-in
  calibration to go back to. The baseline is the rectified one, `nil`
  without both calibrations. A side whose file cannot be read, or whose
  matrices have not their count of values, has no calibration, and
  `error` says why, which is logged.
  """
  @spec in_use(VisionCore.Config.t()) :: {:ok, in_use()} | {:error, String.t()}
  def in_use(config) do
    with {:ok, cameras} <- StereoSupervisor.camera_options(config),
         {:ok, built_in} <- built_in_paths(config) do
      {left, left_error} = read_side(cameras[:left][:calibration_path])
      {right, right_error} = read_side(cameras[:right][:calibration_path])
      error = unreadable(cameras[:prefix], [left_error, right_error])
      source = source(cameras, left, right)

      {:ok,
       %{
         source: source,
         stored_at: if(source == :stored, do: stored_at(cameras)),
         can_reset: stored?(cameras) and exist?(built_in),
         prefix: cameras[:prefix],
         left: left,
         right: right,
         baseline_m: baseline_m(left.calibration, right.calibration),
         error: error
       }}
    end
  end

  @doc """
  Writes both calibrations, to the store when the unit has one, else to
  its calibration paths, and has the unit reload them, or restarts it
  without its pipeline running.
  """
  @spec commit(
          VisionCore.Config.t(),
          %{left: CameraCalibration.t(), right: CameraCalibration.t()},
          keyword()
        ) :: :ok | {:error, String.t()}
  def commit(config, calibrations, opts \\ []) do
    with {:ok, cameras} <- StereoSupervisor.camera_options(config),
         {:ok, paths} <- writable_paths(cameras, @sides) do
      prefix = cameras[:prefix]

      files =
        for side <- @sides,
            do: {paths[side], yaml(calibrations[side], prefix, side)}

      locked(prefix, fn ->
        replace(
          files,
          unit_take(reload_paths(paths[:left], paths[:right]), config, opts),
          prefix,
          opts
        )
      end)
    end
  end

  @doc """
  Removes the stored calibration and has the unit reload the built-in
  one. Refused without a store, with nothing stored, or without a
  built-in calibration to go back to.
  """
  @spec reset(VisionCore.Config.t(), keyword()) :: :ok | {:error, String.t()}
  def reset(config, opts \\ []) do
    with {:ok, cameras} <- StereoSupervisor.camera_options(config),
         {:ok, stores} <- store_paths(cameras),
         {:ok, built_in} <- built_in_paths(config),
         :ok <- check_built_in(built_in) do
      locked(cameras[:prefix], fn ->
        with :ok <- check_stored(stores),
             do:
               replace(
                 Enum.map(stores, &{&1, nil}),
                 unit_take(built_in, config, opts),
                 cameras[:prefix],
                 opts
               )
      end)
    end
  end

  # The side, and why its file gives no calibration, `nil` when it does or there is no file.
  defp read_side(nil), do: {%{path: nil, calibration: nil, yaml: nil}, nil}

  defp read_side(path) do
    case File.read(path) do
      {:ok, yaml} ->
        parse_side(path, yaml)

      {:error, :enoent} ->
        {%{path: path, calibration: nil, yaml: nil}, nil}

      {:error, reason} ->
        {%{path: path, calibration: nil, yaml: nil}, "cannot read #{path}: #{file_error(reason)}"}
    end
  end

  defp parse_side(path, yaml) do
    calibration = CameraCalibration.parse(yaml)

    case CameraCalibration.check_matrices(calibration) do
      :ok -> {%{path: path, calibration: calibration, yaml: yaml}, nil}
      {:error, message} -> {%{path: path, calibration: nil, yaml: yaml}, "#{path}: #{message}"}
    end
  rescue
    exception ->
      {%{path: path, calibration: nil, yaml: yaml},
       "cannot parse #{path}: #{Exception.message(exception)}"}
  end

  defp unreadable(prefix, errors) do
    case Enum.reject(errors, &is_nil/1) do
      [] ->
        nil

      errors ->
        error = Enum.join(errors, "; ")
        Logger.warning("#{__MODULE__}[#{prefix}] #{error}")
        error
    end
  end

  defp source(_cameras, %{calibration: nil}, %{calibration: nil}), do: :none

  defp source(cameras, left, _right) do
    store_path = cameras[:left][:calibration_store_path]
    if store_path && left.path == store_path, do: :stored, else: :built_in
  end

  defp stored_at(cameras) do
    with {:ok, left} <- File.stat(cameras[:left][:calibration_path], time: :posix),
         {:ok, right} <- File.stat(cameras[:right][:calibration_path], time: :posix) do
      DateTime.from_unix!(max(left.mtime, right.mtime))
    else
      {:error, _reason} -> nil
    end
  end

  defp stored?(cameras) do
    case store_paths(cameras) do
      {:ok, stores} -> Enum.any?(stores, &File.exists?/1)
      {:error, _no_store} -> false
    end
  end

  # As the pipeline computes it: the right camera's rectified `P[0,3] = -fx × baseline`.
  defp baseline_m(%CameraCalibration{} = left, %CameraCalibration{} = right) do
    case hd(left.projection_matrix) do
      fx when fx > 0 -> -Enum.at(right.projection_matrix, 3) / fx
      _fx -> nil
    end
  end

  defp baseline_m(_left, _right), do: nil

  # The calibration paths as the unit resolves them without its store.
  defp built_in_paths(%VisionCore.Config{components: components} = config) do
    components =
      Enum.map(components, fn
        {:stereo, opts} when is_list(opts) ->
          {:stereo, Keyword.delete(opts, :calibration_store_dir)}

        component ->
          component
      end)

    with {:ok, cameras} <- StereoSupervisor.camera_options(%{config | components: components}) do
      {:ok, reload_paths(cameras[:left][:calibration_path], cameras[:right][:calibration_path])}
    end
  end

  defp exist?(paths), do: Enum.all?(paths, fn {_key, path} -> path && File.exists?(path) end)

  defp writable_paths(cameras, sides) do
    Enum.reduce_while(sides, {:ok, %{}}, fn side, {:ok, paths} ->
      case writable_path(cameras[side]) do
        nil -> {:halt, {:error, "the #{side} camera has no calibration path to write"}}
        path -> {:cont, {:ok, Map.put(paths, side, path)}}
      end
    end)
  end

  defp writable_path(side_opts),
    do: Keyword.get(side_opts, :calibration_store_path, side_opts[:calibration_path])

  defp store_paths(cameras) do
    case {cameras[:left][:calibration_store_path], cameras[:right][:calibration_store_path]} do
      {nil, _right} -> {:error, "the stereo unit has no calibration store"}
      {left, right} -> {:ok, [left, right]}
    end
  end

  defp check_stored(stores) do
    if Enum.any?(stores, &File.exists?/1), do: :ok, else: {:error, "no calibration is stored"}
  end

  defp check_built_in(built_in) do
    if exist?(built_in), do: :ok, else: {:error, "no built-in calibration to go back to"}
  end

  # With a store, the unit reloads once the other side is stored too.
  defp reload_paths(left, right), do: [left_calibration_path: left, right_calibration_path: right]

  defp unit_take(paths, config, opts),
    do: if(pipeline_running?(opts), do: {:reload, paths, config}, else: {:restart, config})

  defp pipeline_running?(opts),
    do: Keyword.get(opts, :pipeline_running?, &default_pipeline_running?/0).()

  defp yaml(calibration, prefix, side),
    do: CameraCalibration.to_yaml(calibration, "#{prefix}_#{side}")

  # The lock is local to the node, as the files are.
  defp locked(prefix, fun), do: :global.trans({{__MODULE__, prefix}, self()}, fun, [node()])

  # A `nil` yaml removes its file; a `nil` take leaves the unit as it is.
  defp replace(files, take, prefix, opts) do
    with {:ok, previous} <- read_previous(files),
         :ok <- write(files, previous),
         :ok <- take(take, prefix, opts, previous) do
      Outputs.publish(changed_key(prefix), {:stereo_calibration_changed, prefix})
    else
      {:error, message} = refused ->
        Logger.warning("#{__MODULE__}[#{prefix}] #{message}")
        refused
    end
  end

  defp read_previous(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, _yaml}, {:ok, previous} ->
      case File.read(path) do
        {:ok, content} ->
          {:cont, {:ok, [{path, content} | previous]}}

        {:error, :enoent} ->
          {:cont, {:ok, [{path, nil} | previous]}}

        {:error, reason} ->
          {:halt,
           {:error,
            "cannot read the calibration it would replace, #{path}: " <>
              file_error(reason)}}
      end
    end)
  end

  defp write(files, previous) do
    with {:ok, staged} <- stage(files), do: swap(staged, previous)
  end

  defp stage(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, yaml}, {:ok, staged} ->
      case stage_file(path, yaml) do
        {:ok, temporary} ->
          {:cont, {:ok, staged ++ [{path, yaml, temporary}]}}

        {:error, reason} ->
          remove_temporaries(staged)
          {:halt, {:error, "write failed, #{path}: #{file_error(reason)}"}}
      end
    end)
  end

  defp stage_file(_path, nil), do: {:ok, nil}

  defp stage_file(path, yaml) do
    temporary = temporary(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, yaml, [:sync]) do
      {:ok, temporary}
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp swap(staged, previous) do
    staged
    |> Enum.reduce_while({:ok, []}, fn {path, yaml, temporary} = file, {:ok, done} ->
      case swap_file(path, temporary) do
        :ok ->
          log_written(path, yaml)
          {:cont, {:ok, [path | done]}}

        {:error, reason} ->
          remove_temporaries(Enum.drop_while(staged, &(&1 != file)))

          put_back(
            Enum.filter(previous, fn {previous_path, _content} -> previous_path in done end)
          )

          {:halt, {:error, "write failed, #{path}: #{file_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      failed -> failed
    end
  end

  defp swap_file(path, nil), do: put(path, nil)
  defp swap_file(path, temporary), do: File.rename(temporary, path)

  defp remove_temporaries(staged),
    do: for({_path, _yaml, temporary} <- staged, temporary, do: File.rm(temporary))

  defp temporary(path), do: path <> ".tmp"

  defp put(path, nil) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      removed -> removed
    end
  end

  defp put(path, yaml) do
    temporary = temporary(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, yaml, [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp log_written(path, nil), do: Logger.info("#{__MODULE__} removed #{path}")

  defp log_written(path, yaml),
    do: Logger.info("#{__MODULE__} wrote #{byte_size(yaml)} B to #{path}")

  defp put_back(previous) do
    for {path, content} <- previous do
      case put(path, content) do
        :ok ->
          Logger.info("#{__MODULE__} put back what #{path} held")

        {:error, reason} ->
          Logger.error("#{__MODULE__} cannot put back what #{path} held: " <> file_error(reason))
      end
    end
  end

  defp take(nil, _prefix, _opts, _previous), do: :ok

  defp take({:reload, paths, config}, prefix, opts, previous) do
    reload = Keyword.get(opts, :reload, &default_reload(prefix, &1))

    case call(fn -> reload.(paths) end, &reloaded/1) do
      :ok ->
        :ok

      {:error, reason} ->
        put_back(previous)
        {:error, "the stereo unit refused the calibration: #{reason}"}

      {:failed, reason} ->
        put_back(previous)
        reload_in_force(reload, config, prefix)
        {:error, "the stereo unit did not take the calibration: #{reason}"}
    end
  end

  defp take({:restart, config}, prefix, opts, previous) do
    restart_child = Keyword.get(opts, :restart, &default_restart/0)

    restart = fn ->
      StereoSupervisor.forget_row_offset(config)
      restart_child.()
    end

    with {_refused_or_failed, reason} <- call(restart, &restarted/1) do
      Logger.warning("#{__MODULE__}[#{prefix}] the stereo unit did not restart: #{reason}")
      put_back(previous)
      restart_again(restart, prefix)
      {:error, "the stereo unit did not start with this calibration; the log says why"}
    end
  end

  # A reload that raised or exited may have reached the unit: it reloads the files put back.
  defp reload_in_force(reload, config, prefix) do
    with {:ok, cameras} <- StereoSupervisor.camera_options(config),
         paths =
           reload_paths(cameras[:left][:calibration_path], cameras[:right][:calibration_path]),
         :ok <- call(fn -> reload.(paths) end, &reloaded/1) do
      :ok
    else
      {_refused_or_failed, reason} ->
        Logger.error(
          "#{__MODULE__}[#{prefix}] cannot have the stereo unit reload the calibration " <>
            "in force: #{reason}"
        )
    end
  end

  # On the files put back, so that its cameras run again.
  defp restart_again(restart, prefix) do
    with {_refused_or_failed, reason} <- call(restart, &restarted/1),
         do: Logger.error("#{__MODULE__}[#{prefix}] cannot restart the stereo unit: #{reason}")
  end

  # `{:failed, reason}` for a call that raised or exited, which may have reached the unit.
  defp call(fun, answer) do
    answer.(fun.())
  catch
    kind, reason -> {:failed, Exception.format_banner(kind, reason)}
  end

  defp reloaded(:ok), do: :ok
  defp reloaded(other), do: refusal(other)

  # `Supervisor.restart_child/2` answers `{:ok, :undefined}` for a unit that does not start.
  defp restarted({:ok, pid}) when is_pid(pid), do: :ok
  defp restarted({:ok, pid, _info}) when is_pid(pid), do: :ok
  defp restarted({:ok, :undefined}), do: {:error, "it did not start"}
  defp restarted(other), do: refusal(other)

  defp refusal({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp refusal({:error, reason}), do: {:error, inspect(reason)}
  defp refusal(other), do: {:error, inspect(other)}

  defp file_error(reason), do: reason |> :file.format_error() |> List.to_string()

  defp default_reload(prefix, paths),
    do: StereoSupervisor.reload_calibration(VisionCore.Stereo.Pipeline, prefix, paths)

  defp default_pipeline_running?, do: Process.whereis(VisionCore.Stereo.Pipeline) != nil

  defp default_restart do
    with :ok <- Supervisor.terminate_child(VisionCore.Supervisor, StereoSupervisor),
         do: Supervisor.restart_child(VisionCore.Supervisor, StereoSupervisor)
  end
end
