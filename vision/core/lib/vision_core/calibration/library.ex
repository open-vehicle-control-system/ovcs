defmodule VisionCore.Calibration.Library do
  @moduledoc """
  The calibrations the unit keeps, in `VisionCore.Repo`: every one it
  was given stays, under a name, and any of them can be put back in
  force. A target's calibration in force is the one its store files hold.

  A pair's calibration is kept as a `VisionCore.Models.StereoCameraCalibration`,
  a camera's as a `VisionCore.Models.CameraCalibration`, a camera's pose
  as a `VisionCore.Models.CameraPose`; an id
  (`VisionCore.Models.KeptCalibrationId`) names one of any kind.

  The files stay what the pipelines read; `VisionCore.Calibration.Recorder`
  keeps the library and them in step.

  Every call answers when the database is unavailable: the reads as an
  empty library, the writes as an error.
  """
  import Ecto.Query
  require Logger

  alias VisionCore.Camera.Pose
  alias VisionCore.Models
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  @unavailable "saved calibrations unavailable"
  @models %{
    "stereo" => Models.StereoCameraCalibration,
    "camera" => Models.CameraCalibration,
    "pose" => Models.CameraPose
  }
  @pose_suffix "-pose"

  @type cameras :: [{String.t(), CameraCalibration.t()}]

  @typedoc "What a calibration holds: each camera's name with its calibration, or a camera's pose."
  @type figures :: cameras() | Pose.t()

  @typedoc "A calibration kept, of any kind."
  @type kept ::
          Models.StereoCameraCalibration.t()
          | Models.CameraCalibration.t()
          | Models.CameraPose.t()

  @doc """
  Keeps `figures` as a calibration of `target`: a pair's for the cameras
  `left` and `right`, a camera's for one camera, or a camera's pose.

  ## Options

    * `:origin` — where it comes from, required.
    * `:at` — the time it was made, by default now.
    * `:name` — its name, by default that time, in UTC.
    * `:board` — the session's board, `%{columns:, rows:, square_m:}`.
    * `:samples`, `:stereo_rms_px`, `:baseline_m` — the solve's figures.
    * `:rms_px` — each camera's reprojection error, by camera name; a
      pose's, a number.
  """
  @spec record(String.t(), figures(), keyword()) :: {:ok, kept()} | {:error, String.t()}
  def record(target, %Pose{} = pose, opts) do
    figures =
      pose
      |> Models.CameraPose.attributes()
      |> Map.merge(%{
        camera: String.replace_suffix(target, @pose_suffix, ""),
        rms_px: opts[:rms_px]
      })

    insert(Models.CameraPose, target, figures, opts)
  end

  def record(target, cameras, opts) do
    rms_px = Keyword.get(opts, :rms_px, %{})

    case Enum.sort_by(cameras, &elem(&1, 0)) do
      [{"left", left}, {"right", right}] ->
        with {:ok, left} <- lens("left", left, rms_px),
             {:ok, right} <- lens("right", right, rms_px) do
          figures = %{
            left: left,
            right: right,
            stereo_rms_px: opts[:stereo_rms_px],
            baseline_m: opts[:baseline_m]
          }

          insert(Models.StereoCameraCalibration, target, figures, opts)
        end

      [{name, calibration}] ->
        with {:ok, lens} <- lens(name, calibration, rms_px),
             do: insert(Models.CameraCalibration, target, %{camera: name, lens: lens}, opts)

      _other ->
        {:error, "a calibration is of the cameras left and right, or of one camera"}
    end
  end

  defp lens(name, calibration, rms_px) do
    case Models.Lens.attributes(calibration) do
      {:ok, lens} -> {:ok, Map.put(lens, :rms_px, rms_px[name])}
      {:error, reason} -> {:error, "the #{name} camera cannot be kept: #{reason}"}
    end
  end

  defp insert(model, target, figures, opts) do
    now = DateTime.truncate(Keyword.get_lazy(opts, :at, &DateTime.utc_now/0), :second)
    board = Keyword.get(opts, :board) || %{}

    guarded(fn ->
      attributes =
        Map.merge(figures, %{
          target: target,
          name:
            Keyword.get_lazy(opts, :name, fn -> Calendar.strftime(now, "%Y-%m-%d %H:%M UTC") end),
          origin: Keyword.fetch!(opts, :origin),
          board_columns: board[:columns],
          board_rows: board[:rows],
          board_square_m: board[:square_m],
          samples: opts[:samples],
          inserted_at: now
        })

      model |> struct() |> model.changeset(attributes) |> Repo.insert() |> written()
    end)
  end

  @doc """
  The calibrations of `target`, the one kept last first: in the order the
  unit was given them, whatever its clock read.
  """
  @spec list(String.t()) :: [kept()]
  def list(target) do
    Enum.flat_map(Map.values(@models), fn model ->
      Repo.all(from(kept in model, where: kept.target == ^target, order_by: [desc: kept.id]))
    end)
  rescue
    error -> unavailable(error, [])
  catch
    :exit, reason -> unavailable(reason, [])
  end

  @doc "The calibration `id`."
  @spec fetch(String.t()) :: {:ok, kept()} | {:error, :not_found | String.t()}
  def fetch(id) do
    with {:ok, model} <- model(id) do
      guarded(fn ->
        case Repo.get(model, id) do
          nil -> {:error, :not_found}
          kept -> {:ok, kept}
        end
      end)
    end
  end

  @doc "Names the calibration `id`; a name has 1 to 80 characters once trimmed."
  @spec rename(String.t(), String.t()) :: {:ok, kept()} | {:error, :not_found | String.t()}
  def rename(id, name) when is_binary(name) do
    with :ok <- Models.KeptCalibration.check_name(name),
         {:ok, %model{} = kept} <- fetch(id) do
      guarded(fn -> kept |> model.changeset(%{name: name}) |> Repo.update() |> written() end)
    end
  end

  @doc "Removes the calibration `id`, unless it is in force."
  @spec delete(String.t()) :: :ok | {:error, :not_found | :in_force | String.t()}
  def delete(id) do
    with {:ok, model} <- model(id) do
      # One statement: a selection made meanwhile cannot fall between the check and the removal.
      not_in_force = from(kept in model, where: kept.id == ^id and not kept.in_force)

      guarded(fn ->
        cond do
          match?({1, _}, Repo.delete_all(not_in_force)) -> :ok
          Repo.exists?(from(kept in model, where: kept.id == ^id)) -> {:error, :in_force}
          true -> {:error, :not_found}
        end
      end)
    end
  end

  @doc "The calibration in force for `target`, or `nil` for the firmware's or none."
  @spec selected(String.t()) :: kept() | nil
  def selected(target) do
    Enum.find_value(Map.values(@models), fn model ->
      Repo.one(from(kept in model, where: kept.target == ^target and kept.in_force))
    end)
  rescue
    error -> unavailable(error, nil)
  catch
    :exit, reason -> unavailable(reason, nil)
  end

  @doc """
  Puts the calibration `id` in force for `target`, and none of its others;
  none with `nil`, for the firmware's.
  """
  @spec select(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def select(target, nil) do
    guarded(fn ->
      {:ok, :ok} = Repo.transaction(fn -> clear(target) end)
      :ok
    end)
  end

  def select(target, id) do
    case model(id) do
      {:ok, model} -> guarded(fn -> put_in_force(model, target, id) end)
      {:error, :not_found} -> {:error, not_kept(target, id)}
    end
  end

  # The target's others first: the database takes one in force per target at most.
  defp put_in_force(model, target, id) do
    chosen = from(kept in model, where: kept.id == ^id and kept.target == ^target)

    selection =
      Repo.transaction(fn ->
        clear(target)

        case Repo.update_all(chosen, set: [in_force: true]) do
          {1, _} -> :ok
          {0, _} -> Repo.rollback(not_kept(target, id))
        end
      end)

    case selection do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear(target) do
    for model <- Map.values(@models) do
      Repo.update_all(from(kept in model, where: kept.target == ^target and kept.in_force),
        set: [in_force: false]
      )
    end

    :ok
  end

  defp not_kept(target, id), do: "no calibration #{inspect(id)} is kept for #{target}"

  @doc "The newest calibration of `target` that holds `figures`, element for element."
  @spec holding(String.t(), figures()) :: kept() | nil
  def holding(target, figures), do: Enum.find(list(target), &holds?(&1, figures))

  @doc "Whether `kept` holds `figures`, its cameras' lenses or its pose, element for element."
  @spec holds?(kept(), figures()) :: boolean()
  def holds?(%Models.CameraPose{} = kept, %Pose{} = pose),
    do: Models.CameraPose.holds?(kept, pose)

  def holds?(_kept, %Pose{}), do: false
  def holds?(%Models.CameraPose{}, _cameras), do: false

  def holds?(kept, cameras) do
    lenses = lenses(kept)

    length(lenses) == length(cameras) and
      Enum.all?(cameras, fn {name, calibration} ->
        Enum.any?(lenses, fn {lens_name, lens} ->
          lens_name == name and Models.Lens.holds?(lens, calibration)
        end)
      end)
  end

  @doc "The cameras of `kept`, each name with its lens: a pair's left then right, a camera's; none for a pose."
  @spec lenses(kept()) :: [{String.t(), Models.Lens.t()}]
  def lenses(%Models.StereoCameraCalibration{left: left, right: right}),
    do: [{"left", left}, {"right", right}]

  def lenses(%Models.CameraCalibration{camera: camera, lens: lens}), do: [{camera, lens}]
  def lenses(%Models.CameraPose{}), do: []

  defp model(id) do
    case Models.KeptCalibrationId.parse(id) do
      {:ok, kind, _row_id} -> {:ok, Map.fetch!(@models, kind)}
      :error -> {:error, :not_found}
    end
  end

  # A refused name answers its rule, any other refusal as a write that failed.
  defp written({:ok, kept}), do: {:ok, kept}

  defp written({:error, %Ecto.Changeset{} = changeset}) do
    case changeset.errors[:name] do
      {rule, _validation} -> {:error, rule}
      nil -> unavailable(changeset, {:error, @unavailable})
    end
  end

  defp guarded(write) do
    write.()
  rescue
    error -> unavailable(error, {:error, @unavailable})
  catch
    :exit, reason -> unavailable(reason, {:error, @unavailable})
  end

  defp unavailable(reason, answer) do
    Logger.warning("#{@unavailable}: #{inspect(reason)}")
    answer
  end
end
