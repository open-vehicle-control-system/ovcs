defmodule VisionApiWeb.SavedCalibrationController do
  @moduledoc """
  The calibrations the unit saves (`VisionCore.Calibration.saved/2`), as
  `saved-calibrations` resources: listed, for every target or for the one
  `filter[calibration]` names, read, changed and removed. A change, read
  from the JSON body only, names one, puts it in use, or both, the name
  checked first so that a refused change changes nothing; putting one
  in use answers once the unit has taken it, and is refused while a
  calibration session runs. A calibration leaves use when another one
  of its target is put in use, or when the target is reset
  (`POST /api/calibration-resets`). Removing the calibration in use
  first returns its target to the built-in calibration; it is refused
  while a calibration session runs, or without a built-in calibration
  to return to.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Calibration.CommonFields

  @type_name "saved-calibrations"
  @attributes_pointer "/data/attributes"
  @name_pointer "/data/attributes/name"
  @in_use_pointer "/data/attributes/inUse"

  def index(conn, params) do
    config = CalibrationUnit.config()

    case targets(params) do
      {:ok, ids} ->
        saved = Enum.flat_map(ids, &saved(config, &1))
        render(conn, :index, saved: saved)

      {:error, parameter} ->
        JsonApi.error(
          conn,
          400,
          "the saved calibrations are filtered by filter[calibration], one id",
          source: %{parameter: parameter}
        )
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, saved_id} <- parse(id),
         {:ok, saved} <- Calibration.fetch_saved(CalibrationUnit.config(), saved_id) do
      render(conn, :show, saved: saved)
    else
      refusal -> refuse(conn, id, refusal)
    end
  end

  def update(conn, %{"id" => id}) do
    config = CalibrationUnit.config()
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, @type_name, id),
         {:ok, changes} <- fetch_changes(data),
         {:ok, saved_id} <- parse(id),
         :ok <- check_name(changes),
         {:ok, saved} <- Calibration.fetch_saved(config, saved_id),
         :ok <- change_use(config, saved, changes),
         {:ok, changed} <- rename(config, saved_id, changes) do
      render(conn, :show, saved: changed)
    else
      refusal -> refuse(conn, id, refusal)
    end
  end

  defp fetch_changes(%{"attributes" => %{} = attributes}) do
    with {:ok, name} <- optional(attributes, "name", &is_binary/1, "a string"),
         {:ok, in_use} <- optional(attributes, "inUse", &is_boolean/1, "a boolean") do
      case Map.reject(%{name: name, in_use: in_use}, fn {_change, value} -> is_nil(value) end) do
        none when map_size(none) == 0 -> no_change()
        changes -> {:ok, changes}
      end
    end
  end

  defp fetch_changes(_data), do: no_change()

  defp no_change,
    do:
      {:error, 400, "data.attributes takes a name, a string, or inUse, a boolean",
       [source: @attributes_pointer]}

  defp optional(attributes, key, valid?, what) do
    case Map.fetch(attributes, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        if valid?.(value),
          do: {:ok, value},
          else:
            {:error, 400, "data.attributes.#{key} is #{what}",
             [source: "#{@attributes_pointer}/#{key}"]}
    end
  end

  defp check_name(%{name: name}) do
    case CommonFields.check_name(name) do
      :ok -> :ok
      {:error, rule} -> invalid_name(rule)
    end
  end

  defp check_name(_changes), do: :ok

  defp invalid_name(rule), do: {:error, 422, rule, [source: @name_pointer, title: "Invalid name"]}

  defp change_use(config, %{in_use: false, saved: saved}, %{in_use: true}) do
    with :ok <- CalibrationUnit.check_idle("Not put in use"),
         do: use_task(config, saved.id)
  end

  defp change_use(_config, %{in_use: true}, %{in_use: false}),
    do:
      {:error, 422,
       "the unit runs on this calibration until another one is put in use or the calibration is reset",
       [source: @in_use_pointer, title: "Still in use"]}

  defp change_use(_config, _saved, _changes), do: :ok

  # Outlives the request: a stereo pair's commit may wait for its unit to restart.
  defp use_task(config, saved_id) do
    case CalibrationUnit.run("putting a calibration in use", fn ->
           Calibration.use_saved(config, saved_id)
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        {:error, :not_found}

      {:ok, {:error, reason}} ->
        if CalibrationUnit.saved_unavailable?(reason),
          do: CalibrationUnit.saved_unavailable(),
          else: {:error, 422, reason, [title: "Not put in use"]}

      :failed ->
        {:error, 500, "putting the calibration in use failed; the log says why", []}
    end
  end

  defp rename(config, saved_id, %{name: name}) do
    case Calibration.rename_saved(config, saved_id, name) do
      {:error, reason} when is_binary(reason) ->
        if CalibrationUnit.saved_unavailable?(reason),
          do: {:error, reason},
          else: invalid_name(reason)

      answer ->
        answer
    end
  end

  defp rename(config, saved_id, _changes), do: Calibration.fetch_saved(config, saved_id)

  def delete(conn, %{"id" => id}) do
    config = CalibrationUnit.config()

    with {:ok, saved_id} <- parse(id),
         {:ok, saved} <- Calibration.fetch_saved(config, saved_id),
         :ok <- check_leavable(saved),
         :ok <- delete_task(config, saved_id) do
      send_resp(conn, :no_content, "")
    else
      {:error, :in_use} ->
        JsonApi.error(
          conn,
          409,
          "the unit runs on this calibration and has no built-in calibration to return to",
          title: "In use"
        )

      {:error, {:reset, reason}} ->
        JsonApi.error(conn, 500, reason)

      refusal ->
        refuse(conn, id, refusal)
    end
  end

  # A session's apply would replace the built-in calibration the removal returns to.
  defp check_leavable(%{in_use: true}), do: CalibrationUnit.check_idle("Not deleted")
  defp check_leavable(_saved), do: :ok

  # Outlives the request: removing the calibration in use may wait for the stereo unit to restart.
  defp delete_task(config, saved_id) do
    case CalibrationUnit.run("the removal", fn -> Calibration.delete_saved(config, saved_id) end) do
      {:ok, outcome} -> outcome
      :failed -> {:error, {:reset, "the removal failed; the log says why"}}
    end
  end

  # The ids of the targets to list, or the query parameter that is no filter of the route.
  defp targets(%{"filter" => %{"calibration" => id} = filter})
       when is_binary(id) and map_size(filter) == 1,
       do: {:ok, [id]}

  defp targets(%{"filter" => %{} = filter}) do
    case Map.keys(filter) -- ["calibration"] do
      [key | _others] -> {:error, "filter[#{key}]"}
      [] -> {:error, "filter[calibration]"}
    end
  end

  defp targets(%{"filter" => _text}), do: {:error, "filter"}

  defp targets(_params), do: {:ok, Enum.map(CalibrationUnit.targets(), & &1.id)}

  defp saved(config, id) do
    case Calibration.saved(config, id) do
      {:ok, saved} -> saved
      {:error, :not_found} -> []
    end
  end

  defp parse(id) do
    case CalibrationUnit.saved_id(id) do
      {:ok, saved_id} -> {:ok, saved_id}
      :error -> {:error, :not_found}
    end
  end

  defp refuse(conn, id, {:error, :not_found}),
    do: JsonApi.error(conn, 404, "no saved calibration #{id}")

  defp refuse(conn, _id, {:error, _status, _detail, _options} = refusal),
    do: JsonApi.refuse(conn, refusal)

  defp refuse(conn, id, {:error, _reason}),
    do: refuse(conn, id, CalibrationUnit.saved_unavailable())
end
