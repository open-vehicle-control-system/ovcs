defmodule VisionApiWeb.SavedCalibrationController do
  @moduledoc """
  The calibrations the unit keeps (`VisionCore.Calibration.saved/2`), as
  `saved-calibrations` resources: listed, for every target or for the one
  `filter[calibration]` names, read, renamed and removed. A rename is
  read from the JSON body only. The calibration in force is not removed.

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

      {:error, detail} ->
        JsonApi.error(conn, 400, detail, source: %{parameter: "filter[calibration]"})
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
      {:error, reason} when is_binary(reason) ->
        JsonApi.error(conn, 422, reason, source: @name_pointer, title: "Invalid name")

      refusal ->
        refuse(conn, id, refusal)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, saved_id} <- parse(id),
         :ok <- Calibration.delete_saved(CalibrationUnit.config(), saved_id) do
      send_resp(conn, :no_content, "")
    else
      {:error, :in_force} ->
        JsonApi.error(conn, 409, "the unit runs on this calibration", title: "In force")

      refusal ->
        refuse(conn, id, refusal)
    end
  end

  defp targets(%{"filter" => %{"calibration" => id}}) when is_binary(id), do: {:ok, [id]}

  defp targets(%{"filter" => _other}),
    do: {:error, "filter[calibration] names one of the calibrations"}

  defp targets(_params), do: {:ok, Enum.map(CalibrationUnit.targets(), & &1.id)}

  defp kept(config, id) do
    case Calibration.saved(config, id) do
      {:ok, kept} -> kept
      {:error, :not_found} -> []
    end
  end

  defp parse(id) do
    case Integer.parse(id) do
      {saved_id, ""} -> {:ok, saved_id}
      _other -> {:error, :not_found}
    end
  end

  defp fetch_name(%{"attributes" => %{"name" => name}}) when is_binary(name), do: {:ok, name}

  defp fetch_name(_data),
    do: {:error, 400, "data.attributes.name is required, a string", [source: @name_pointer]}

  defp refuse(conn, id, {:error, :not_found}),
    do: JsonApi.error(conn, 404, "no saved calibration #{id}")

  defp refuse(conn, _id, {:error, status, detail, options}),
    do: JsonApi.error(conn, status, detail, options)

  defp refuse(conn, _id, {:error, reason}) when is_binary(reason),
    do: JsonApi.error(conn, 503, reason, title: "Saved calibrations unavailable")
end
