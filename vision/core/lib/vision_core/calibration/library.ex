defmodule VisionCore.Calibration.Library do
  @moduledoc """
  The calibrations the unit keeps, in `VisionCore.Repo`: every one it
  was given stays, under a name, and any of them can be put back in
  force. A target's selection says which one its store files hold.

  The files stay what the pipelines read; `VisionCore.Calibration.Recorder`
  keeps the library and them in step.

  Every call answers when the database is unavailable: the reads as an
  empty library, the writes as an error.
  """
  import Ecto.Query
  require Logger

  alias VisionCore.Calibration.{Saved, SavedCamera, Selection}
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  @unavailable "saved calibrations unavailable"
  @name_rule "a name has 1 to 80 characters"
  @max_name 80

  @type cameras :: [{String.t(), CameraCalibration.t()}]

  @doc """
  Keeps `cameras`, each camera's name with its calibration, as a
  calibration of `target`.

  ## Options

    * `:origin` — where it comes from, required.
    * `:at` — the time it was made, by default now.
    * `:name` — its name, by default that time, in UTC.
    * `:board` — the session's board, `%{columns:, rows:, square_m:}`.
    * `:samples`, `:stereo_rms_px`, `:baseline_m` — the solve's figures.
    * `:rms_px` — each camera's reprojection error, by camera name.
  """
  @spec record(String.t(), cameras(), keyword()) :: {:ok, Saved.t()} | {:error, String.t()}
  def record(target, cameras, opts) do
    rms_px = Keyword.get(opts, :rms_px, %{})

    with {:ok, rows} <- camera_rows(cameras, rms_px) do
      now = DateTime.truncate(Keyword.get_lazy(opts, :at, &DateTime.utc_now/0), :second)
      board = Keyword.get(opts, :board) || %{}

      guarded(fn ->
        Repo.insert(%Saved{
          target: target,
          name: Keyword.get_lazy(opts, :name, fn -> Calendar.strftime(now, "%Y-%m-%d %H:%M") end),
          origin: Keyword.fetch!(opts, :origin),
          board_columns: board[:columns],
          board_rows: board[:rows],
          board_square_m: board[:square_m],
          samples: opts[:samples],
          stereo_rms_px: opts[:stereo_rms_px],
          baseline_m: opts[:baseline_m],
          cameras: rows,
          inserted_at: now
        })
      end)
    end
  end

  @doc "The calibrations of `target`, the newest first, with their cameras."
  @spec list(String.t()) :: [Saved.t()]
  def list(target) do
    Repo.all(
      from(saved in Saved,
        where: saved.target == ^target,
        order_by: [desc: saved.inserted_at, desc: saved.id],
        preload: :cameras
      )
    )
  rescue
    error -> unavailable(error, [])
  catch
    :exit, reason -> unavailable(reason, [])
  end

  @doc "The calibration `id`, with its cameras."
  @spec fetch(integer()) :: {:ok, Saved.t()} | {:error, :not_found | String.t()}
  def fetch(id) do
    guarded(fn ->
      case Repo.get(Saved, id) do
        nil -> {:error, :not_found}
        saved -> {:ok, Repo.preload(saved, :cameras)}
      end
    end)
  end

  @doc "Names the calibration `id`; a name has 1 to #{@max_name} characters once trimmed."
  @spec rename(integer(), String.t()) :: {:ok, Saved.t()} | {:error, :not_found | String.t()}
  def rename(id, name) when is_binary(name) do
    name = String.trim(name)

    if String.length(name) in 1..@max_name do
      with {:ok, saved} <- fetch(id),
           do: guarded(fn -> saved |> Ecto.Changeset.change(name: name) |> Repo.update() end)
    else
      {:error, @name_rule}
    end
  end

  @doc "Removes the calibration `id` and its cameras, unless it is in force."
  @spec delete(integer()) :: :ok | {:error, :not_found | :in_force | String.t()}
  def delete(id) do
    guarded(fn ->
      cond do
        Repo.exists?(from(selection in Selection, where: selection.calibration_id == ^id)) ->
          {:error, :in_force}

        match?({1, _}, Repo.delete_all(from(saved in Saved, where: saved.id == ^id))) ->
          :ok

        true ->
          {:error, :not_found}
      end
    end)
  end

  @doc "The calibration in force for `target`, or `nil` for the firmware's or none."
  @spec selected(String.t()) :: Saved.t() | nil
  def selected(target) do
    Repo.one(
      from(saved in Saved,
        join: selection in Selection,
        on: selection.calibration_id == saved.id,
        where: selection.target == ^target,
        preload: :cameras
      )
    )
  rescue
    error -> unavailable(error, nil)
  catch
    :exit, reason -> unavailable(reason, nil)
  end

  @doc "Marks the calibration `id` as the one in force for `target`, or none with `nil`."
  @spec select(String.t(), integer() | nil) :: :ok | {:error, String.t()}
  def select(target, nil) do
    guarded(fn ->
      Repo.delete_all(from(selection in Selection, where: selection.target == ^target))
      :ok
    end)
  end

  def select(target, id) do
    guarded(fn ->
      Repo.insert!(%Selection{target: target, calibration_id: id},
        on_conflict: {:replace, [:calibration_id]},
        conflict_target: :target
      )

      :ok
    end)
  end

  @doc "The newest calibration of `target` whose cameras are `cameras`, element for element."
  @spec holding(String.t(), cameras()) :: Saved.t() | nil
  def holding(target, cameras), do: Enum.find(list(target), &holds?(&1, cameras))

  @doc "Whether the cameras of `saved` are `cameras`, element for element."
  @spec holds?(Saved.t(), cameras()) :: boolean()
  def holds?(%Saved{} = saved, cameras) do
    length(saved.cameras) == length(cameras) and
      Enum.all?(cameras, fn {name, calibration} ->
        Enum.any?(saved.cameras, &(&1.name == name and SavedCamera.holds?(&1, calibration)))
      end)
  end

  defp camera_rows(cameras, rms_px) do
    Enum.reduce_while(cameras, {:ok, []}, fn {name, calibration}, {:ok, rows} ->
      case SavedCamera.from_calibration(name, calibration) do
        {:ok, row} -> {:cont, {:ok, rows ++ [%{row | rms_px: rms_px[name]}]}}
        {:error, reason} -> {:halt, {:error, "the #{name} camera cannot be kept: #{reason}"}}
      end
    end)
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
