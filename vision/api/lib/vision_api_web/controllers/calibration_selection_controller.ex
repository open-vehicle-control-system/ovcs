defmodule VisionApiWeb.CalibrationSelectionController do
  @moduledoc """
  Puts a calibration the unit keeps back in force, created as a
  `calibration-selections` action resource whose `savedCalibration`
  relationship names one of the `saved-calibrations`. It answers once
  the unit has taken the calibration, with the action and its
  relationship; the calibration in use then comes through the
  `calibration` channel. The action is read from the JSON body only.

  Refused while a calibration session runs: its apply would replace the
  selection.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration

  @type_name "calibration-selections"
  @saved_pointer "/data/relationships/savedCalibration"

  def create(conn, _params) do
    with {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, id, saved_id} <- saved(data),
         :ok <- CalibrationUnit.check_idle("Not selected"),
         :ok <- select(id, saved_id) do
      conn
      |> put_status(:created)
      |> json(%{
        data:
          JsonApi.resource(@type_name, JsonApi.action_id(), %{}, %{
            savedCalibration: JsonApi.to_one("saved-calibrations", id)
          })
      })
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp saved(%{
         "relationships" => %{
           "savedCalibration" => %{"data" => %{"type" => "saved-calibrations", "id" => id}}
         }
       })
       when is_binary(id) do
    case CalibrationUnit.saved_id(id) do
      {:ok, saved_id} -> {:ok, id, saved_id}
      :error -> not_found(id)
    end
  end

  defp saved(_data),
    do:
      {:error, 400, "savedCalibration must name one of the saved-calibrations",
       [source: @saved_pointer]}

  # Outlives the request: a stereo pair's commit may wait for its unit to restart.
  defp select(id, saved_id) do
    config = CalibrationUnit.config()

    case CalibrationUnit.run("the selection", fn -> Calibration.use_saved(config, saved_id) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        not_found(id)

      {:ok, {:error, reason}} ->
        if CalibrationUnit.saved_unavailable?(reason),
          do: CalibrationUnit.saved_unavailable(),
          else: {:error, 422, reason, [title: "Not selected"]}

      :failed ->
        {:error, 500, "the selection failed; the log says why", []}
    end
  end

  defp not_found(id),
    do: {:error, 404, "no saved calibration #{id}", [source: @saved_pointer]}
end
