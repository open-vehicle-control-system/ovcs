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
  require Logger

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Calibration.Session

  @type_name "calibration-selections"
  @saved_pointer "/data/relationships/savedCalibration"

  def create(conn, _params) do
    with {:ok, data} <- fetch_data(JsonApi.document(conn)),
         {:ok, id, saved_id} <- saved(data),
         :ok <- check_idle(),
         :ok <- select(id, saved_id) do
      action_id = Integer.to_string(System.unique_integer([:positive, :monotonic]))

      conn
      |> put_status(:created)
      |> json(%{
        data:
          JsonApi.resource(@type_name, action_id, %{}, %{
            savedCalibration: JsonApi.to_one("saved-calibrations", id)
          })
      })
    else
      {:error, status, detail, options} -> JsonApi.error(conn, status, detail, options)
    end
  end

  defp fetch_data(%{"data" => %{"type" => @type_name, "id" => _id}}),
    do: JsonApi.client_id_refusal()

  defp fetch_data(%{"data" => %{"type" => @type_name} = data}), do: {:ok, data}

  defp fetch_data(%{"data" => %{"type" => _other}}),
    do: {:error, 409, "type must be #{@type_name}", [source: "/data/type"]}

  defp fetch_data(_document), do: {:error, 400, "data with a type is required", [source: "/data"]}

  defp saved(%{
         "relationships" => %{
           "savedCalibration" => %{"data" => %{"type" => "saved-calibrations", "id" => id}}
         }
       })
       when is_binary(id) do
    case Integer.parse(id) do
      {saved_id, ""} -> {:ok, id, saved_id}
      _other -> not_found(id)
    end
  end

  defp saved(_data),
    do:
      {:error, 400, "savedCalibration must name one of the saved-calibrations",
       [source: @saved_pointer]}

  defp check_idle do
    case GenServer.whereis(Session) && Session.state().phase do
      phase when phase in [nil, :idle] -> :ok
      _running -> {:error, 409, "a calibration session is running", [title: "Not selected"]}
    end
  end

  # Outlives the request: a stereo pair's commit may wait for its unit to restart.
  defp select(id, saved_id) do
    config = CalibrationUnit.config()

    task =
      Task.Supervisor.async_nolink(Calibration.Tasks, fn ->
        Calibration.use_saved(config, saved_id)
      end)

    case Task.yield(task, :infinity) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        not_found(id)

      {:ok, {:error, reason}} ->
        {:error, 422, reason, [title: "Not selected"]}

      {:exit, reason} ->
        Logger.error("#{__MODULE__} selection failed: #{Exception.format_exit(reason)}")
        {:error, 500, "the selection failed; the log says why", []}
    end
  end

  defp not_found(id),
    do: {:error, 404, "no saved calibration #{id}", [source: @saved_pointer]}
end
