defmodule VisionApiWeb.CalibrationSessionController do
  @moduledoc """
  Serves `calibration-sessions`: creating one starts a calibration session
  on the `calibration` it names, with its `board`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationSessionJSON, CalibrationUnit, JsonApi}
  alias VisionCore.Calibration.{Board, Session}

  @type_name "calibration-sessions"
  @max_square_mm round(Board.max_square_m() * 1000)

  plug :put_view, json: CalibrationSessionJSON, jsonapi: CalibrationSessionJSON

  def create(conn, _params) do
    with :ok <- CalibrationUnit.check_session(),
         {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, id} <- CalibrationUnit.fetch_target_id(data),
         {:ok, board} <- board(data),
         :ok <- start(id, board) do
      conn
      |> put_status(:created)
      |> render(:show, type: @type_name, id: JsonApi.action_id(), session: Session.state())
    else
      refusal -> JsonApi.refuse(conn, refusal)
    end
  end

  defp start(id, board) do
    case Session.start(id, board) do
      :ok -> :ok
      {:error, :not_found} -> CalibrationUnit.target_not_found(id)
      {:error, reason} -> {:error, start_status(), reason, [title: "Not started"]}
    end
  end

  defp start_status, do: if(Session.state().phase == :idle, do: 422, else: 409)

  defp board(%{"attributes" => %{"board" => %{} = board}}) do
    with {:ok, square_m} <- square_m(board["squareMm"]),
         {:ok, board} <- Board.new(board["columns"], board["rows"], square_m) do
      {:ok, board}
    else
      {:error, reason} ->
        {:error, 422, reason, [source: "/data/attributes/board", title: "Invalid board"]}
    end
  end

  defp board(_data),
    do:
      {:error, 422, "board with columns, rows and squareMm is required",
       [source: "/data/attributes/board", title: "Invalid board"]}

  # Checked before the division, which raises for an integer no float holds.
  defp square_m(square_mm)
       when is_number(square_mm) and square_mm > 0 and square_mm <= @max_square_mm,
       do: {:ok, square_mm / 1000}

  defp square_m(_square_mm),
    do: {:error, "squareMm must be a number above 0 and at most #{@max_square_mm}"}
end
