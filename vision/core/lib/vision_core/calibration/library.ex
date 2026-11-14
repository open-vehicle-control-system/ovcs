defmodule VisionCore.Calibration.Library do
  @moduledoc """
  The calibrations the unit saves, in `VisionCore.Repo`: every one it
  was given stays, under a name, and any of them can be put back in use.
  A target's calibration in use is the one its store files hold.

  A pair's calibration is saved as a `VisionCore.Models.StereoCameraCalibration`,
  a camera's as a `VisionCore.Models.CameraCalibration`, a camera's pose
  as a `VisionCore.Models.CameraPose`; its id, a UUID, names one of any
  kind.

  The files stay what the pipelines read; `VisionCore.Calibration.Recorder`
  keeps the library and them in step.

  Every call answers when the database is unavailable: the reads as an
  empty library, the writes as an error.
  """
  import Ecto.Query
  require Logger

  alias VisionCore.Calibration.CommonFields
  alias VisionCore.Camera.Pose
  alias VisionCore.Models
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  @unavailable "saved calibrations unavailable"
  @models [Models.StereoCameraCalibration, Models.CameraCalibration, Models.CameraPose]
  @pose_suffix "-pose"

  @type cameras :: [{String.t(), CameraCalibration.t()}]

  @typedoc "What a calibration holds: each camera's name with its calibration, or a camera's pose."
  @type figures :: cameras() | Pose.t()

  @typedoc "A saved calibration, of any kind."
  @type saved ::
          Models.StereoCameraCalibration.t()
          | Models.CameraCalibration.t()
          | Models.CameraPose.t()

  @doc """
  Saves `figures` as a calibration of `target`: a pair's for the cameras
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
  @spec record(String.t(), figures(), keyword()) :: {:ok, saved()} | {:error, String.t()}
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
      {:error, reason} -> {:error, "the #{name} camera cannot be saved: #{reason}"}
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
  The calibrations of `target`, the one saved last first: in the order the
  unit was given them, whatever its clock read.
  """
  @spec list(String.t()) :: [saved()]
  def list(target) do
    # SQLite's rowid follows the order rows were inserted in; a UUID carries none.
    Enum.flat_map(@models, fn model ->
      Repo.all(
        from(saved in model, where: saved.target == ^target, order_by: [desc: fragment("rowid")])
      )
    end)
  rescue
    error -> unavailable(error, [])
  catch
    :exit, reason -> unavailable(reason, [])
  end

  @doc "The calibration `id`."
  @spec fetch(String.t()) :: {:ok, saved()} | {:error, :not_found | String.t()}
  def fetch(id) do
    with {:ok, id} <- uuid(id) do
      guarded(fn ->
        case Enum.find_value(@models, &Repo.get(&1, id)) do
          nil -> {:error, :not_found}
          saved -> {:ok, saved}
        end
      end)
    end
  end

  @doc "Names the calibration `id`; a name has 1 to 80 characters once trimmed."
  @spec rename(String.t(), String.t()) :: {:ok, saved()} | {:error, :not_found | String.t()}
  def rename(id, name) when is_binary(name) do
    with :ok <- CommonFields.check_name(name),
         {:ok, %model{} = saved} <- fetch(id) do
      guarded(fn -> saved |> model.changeset(%{name: name}) |> Repo.update() |> written() end)
    end
  end

  @doc "Removes the calibration `id`, unless it is in use."
  @spec delete(String.t()) :: :ok | {:error, :not_found | :in_use | String.t()}
  def delete(id) do
    with {:ok, id} <- uuid(id) do
      guarded(fn ->
        cond do
          Enum.any?(@models, &delete_not_in_use(&1, id)) ->
            :ok

          Enum.any?(@models, &Repo.exists?(from(saved in &1, where: saved.id == ^id))) ->
            {:error, :in_use}

          true ->
            {:error, :not_found}
        end
      end)
    end
  end

  # One statement: a calibration put in use meanwhile cannot fall between the check and the removal.
  defp delete_not_in_use(model, id) do
    not_in_use = from(saved in model, where: saved.id == ^id and not saved.in_use)
    match?({1, _}, Repo.delete_all(not_in_use))
  end

  @doc "The calibration in use for `target`, or `nil` for the firmware's or none."
  @spec in_use(String.t()) :: saved() | nil
  def in_use(target) do
    Enum.find_value(@models, fn model ->
      Repo.one(from(saved in model, where: saved.target == ^target and saved.in_use))
    end)
  rescue
    error -> unavailable(error, nil)
  catch
    :exit, reason -> unavailable(reason, nil)
  end

  @doc """
  Puts the calibration `id` in use for `target`, and none of its others;
  none with `nil`, for the firmware's.
  """
  @spec put_in_use(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def put_in_use(target, nil) do
    guarded(fn ->
      {:ok, :ok} = Repo.transaction(fn -> clear(target) end)
      :ok
    end)
  end

  def put_in_use(target, id) do
    case uuid(id) do
      {:ok, id} -> guarded(fn -> mark_in_use(target, id) end)
      {:error, :not_found} -> {:error, not_saved(target, id)}
    end
  end

  # The target's others first: the database takes one in use per target at most.
  defp mark_in_use(target, id) do
    marked =
      Repo.transaction(fn ->
        clear(target)

        chosen =
          Enum.sum_by(@models, fn model ->
            from(saved in model, where: saved.id == ^id and saved.target == ^target)
            |> Repo.update_all(set: [in_use: true])
            |> elem(0)
          end)

        if chosen == 0, do: Repo.rollback(not_saved(target, id)), else: :ok
      end)

    case marked do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear(target) do
    for model <- @models do
      Repo.update_all(from(saved in model, where: saved.target == ^target and saved.in_use),
        set: [in_use: false]
      )
    end

    :ok
  end

  defp not_saved(target, id), do: "no calibration #{inspect(id)} is saved for #{target}"

  @doc "The newest calibration of `target` that holds `figures`, element for element."
  @spec holding(String.t(), figures()) :: saved() | nil
  def holding(target, figures), do: Enum.find(list(target), &holds?(&1, figures))

  @doc "Whether `saved` holds `figures`, its cameras' lenses or its pose, element for element."
  @spec holds?(saved(), figures()) :: boolean()
  def holds?(%Models.CameraPose{} = saved, %Pose{} = pose),
    do: Models.CameraPose.holds?(saved, pose)

  def holds?(_saved, %Pose{}), do: false
  def holds?(%Models.CameraPose{}, _cameras), do: false

  def holds?(saved, cameras) do
    lenses = lenses(saved)

    length(lenses) == length(cameras) and
      Enum.all?(cameras, fn {name, calibration} ->
        Enum.any?(lenses, fn {lens_name, lens} ->
          lens_name == name and Models.Lens.holds?(lens, calibration)
        end)
      end)
  end

  @doc "The cameras of `saved`, each name with its lens: a pair's left then right, a camera's; none for a pose."
  @spec lenses(saved()) :: [{String.t(), Models.Lens.t()}]
  def lenses(%Models.StereoCameraCalibration{left: left, right: right}),
    do: [{"left", left}, {"right", right}]

  def lenses(%Models.CameraCalibration{camera: camera, lens: lens}), do: [{camera, lens}]
  def lenses(%Models.CameraPose{}), do: []

  # An id is a UUID as the unit writes it: lower case, with its hyphens.
  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, id}
      _other -> {:error, :not_found}
    end
  end

  # A refused name answers its rule, any other refusal as a write that failed.
  defp written({:ok, saved}), do: {:ok, saved}

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
