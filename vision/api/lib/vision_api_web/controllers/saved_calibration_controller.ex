defmodule VisionApiWeb.SavedCalibrationController do
  @moduledoc """
  The calibrations the unit keeps (`VisionCore.Calibration.saved/2`), as
  `saved-calibrations` resources: listed, for every target or for the one
  `filter[calibration]` names, read, renamed and removed. A rename is
  read from the JSON body only. Removing the calibration in force first
  returns its target to the built-in calibration; it is refused while a
  calibration session runs, or without a built-in calibration to return
  to.

  Putting one back in force is a `calibration-selections` action
  (`VisionApiWeb.CalibrationSelectionController`).
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration

  @type_name "saved-calibrations"
  @name_pointer "/data/attributes/name"

  def index(conn, params) do
    config = CalibrationUnit.config()

    case targets(params) do
      {:ok, ids} ->
        kept = Enum.flat_map(ids, &kept(config, &1))
        render(conn, :index, kept: kept)

      {:error, parameter} ->
        JsonApi.error(
          conn,
          400,
          "the calibrations kept are filtered by filter[calibration], one id",
          source: %{parameter: parameter}
        )
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, saved_id} <- parse(id),
         {:ok, kept} <- Calibration.fetch_saved(CalibrationUnit.config(), saved_id) do
      render(conn, :show, kept: kept)
    else
      refusal -> refuse(conn, id, refusal)
    end
  end

  def update(conn, %{"id" => id}) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, @type_name, id),
         {:ok, name} <- fetch_name(data),
         {:ok, saved_id} <- parse(id),
         {:ok, kept} <- Calibration.rename_saved(CalibrationUnit.config(), saved_id, name) do
      render(conn, :show, kept: kept)
    else
      {:error, reason} = refusal when is_binary(reason) ->
        if CalibrationUnit.saved_unavailable?(reason),
          do: refuse(conn, id, refusal),
          else: JsonApi.error(conn, 422, reason, source: @name_pointer, title: "Invalid name")

      refusal ->
        refuse(conn, id, refusal)
    end
  end

  def delete(conn, %{"id" => id}) do
    config = CalibrationUnit.config()

    with {:ok, saved_id} <- parse(id),
         {:ok, kept} <- Calibration.fetch_saved(config, saved_id),
         :ok <- check_leavable(kept),
         :ok <- delete_task(config, saved_id) do
      send_resp(conn, :no_content, "")
    else
      {:error, :in_force} ->
        JsonApi.error(
          conn,
          409,
          "the unit runs on this calibration and has no built-in calibration to return to",
          title: "In force"
        )

      {:error, {:reset, reason}} ->
        JsonApi.error(conn, 500, reason)

      refusal ->
        refuse(conn, id, refusal)
    end
  end

  # A session's apply would replace the built-in calibration the removal returns to.
  defp check_leavable(%{in_force: true}), do: CalibrationUnit.check_idle("Not deleted")
  defp check_leavable(_kept), do: :ok

  # Outlives the request: removing the calibration in force may wait for the stereo unit to restart.
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

  defp kept(config, id) do
    case Calibration.saved(config, id) do
      {:ok, kept} -> kept
      {:error, :not_found} -> []
    end
  end

  defp parse(id) do
    case CalibrationUnit.saved_id(id) do
      {:ok, saved_id} -> {:ok, saved_id}
      :error -> {:error, :not_found}
    end
  end

  defp fetch_name(%{"attributes" => %{"name" => name}}) when is_binary(name), do: {:ok, name}

  defp fetch_name(_data),
    do: {:error, 400, "data.attributes.name is required, a string", [source: @name_pointer]}

  defp refuse(conn, id, {:error, :not_found}),
    do: JsonApi.error(conn, 404, "no saved calibration #{id}")

  defp refuse(conn, _id, {:error, _status, _detail, _options} = refusal),
    do: JsonApi.refuse(conn, refusal)

  defp refuse(conn, id, {:error, _reason}),
    do: refuse(conn, id, CalibrationUnit.saved_unavailable())
end
