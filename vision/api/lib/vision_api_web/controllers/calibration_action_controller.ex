defmodule VisionApiWeb.CalibrationActionController do
  @moduledoc """
  The calibration session's actions and the return to the built-in
  calibration, created as action resources that answer with the session
  after the action. The action is read from the JSON body only: a form or
  a query string, which another site's page can send without asking, is
  refused.

  An apply answers once it has begun, with the session `applying`; its
  outcome comes through the `calibration` channel.
  """
  use VisionApiWeb, :controller
  require Logger

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration.{Board, Session}
  alias VisionCore.Stereo.Calibration

  def start(conn, _params) do
    act(conn, "calibration-sessions", fn data, _config ->
      with {:ok, board} <- board(data) do
        case Session.start(board) do
          :ok -> :ok
          {:error, reason} -> {:error, start_status(), "Not started", reason, nil}
        end
      end
    end)
  end

  def cancel(conn, _params) do
    act(conn, "calibration-cancels", fn _data, _config ->
      refused(Session.cancel(), 409, "Not cancelled")
    end)
  end

  def solve(conn, _params) do
    act(conn, "calibration-solves", fn _data, _config ->
      refused(Session.solve(), 422, "Not solved")
    end)
  end

  def apply(conn, _params) do
    act(conn, "calibration-applies", fn _data, _config ->
      refused(Session.apply(), 422, "Not applied")
    end)
  end

  def reset(conn, _params) do
    act(conn, "calibration-resets", fn _data, config ->
      config |> reset_task() |> refused(422, "Not reset")
    end)
  end

  # Outlives the request: a reset may wait for the stereo unit to restart.
  defp reset_task(config) do
    task =
      Task.Supervisor.async_nolink(VisionCore.Calibration.Tasks, fn ->
        Calibration.reset(config)
      end)

    case Task.yield(task, :infinity) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        Logger.error("#{__MODULE__} reset failed: #{Exception.format_exit(reason)}")
        {:failed, "the reset failed; the log says why"}
    end
  end

  defp act(conn, type, run) do
    with {:ok, config, prefix} <- unit(),
         {:ok, data} <- fetch_data(conn.body_params, type),
         :ok <- run.(data, config) do
      id = Integer.to_string(System.unique_integer([:positive, :monotonic]))

      conn
      |> put_status(:created)
      |> render(:show, type: type, id: id, session: Session.state(), prefix: prefix)
    else
      {:error, status, title, detail, pointer} ->
        JsonApi.error(conn, status, title, detail, pointer)
    end
  end

  defp unit do
    case CalibrationUnit.fetch() do
      {:ok, config, prefix} ->
        if GenServer.whereis(Session),
          do: {:ok, config, prefix},
          else:
            {:error, 503, "Calibration unavailable", "the calibration session is not running",
             nil}

      :error ->
        {:error, 404, "Not Found", "the unit has no stereo cameras: no :stereo component", nil}
    end
  end

  defp refused(:ok, _status, _title), do: :ok

  defp refused({:failed, reason}, _status, _title),
    do: {:error, 500, "Internal Server Error", reason, nil}

  defp refused({:error, reason}, status, title), do: {:error, status, title, reason, nil}

  defp start_status, do: if(Session.state().phase == :idle, do: 422, else: 409)

  defp fetch_data(%{"data" => %{"type" => type} = data}, type), do: {:ok, data}

  defp fetch_data(%{"data" => %{"type" => _other}}, type),
    do: {:error, 409, "Conflict", "type must be #{type}", "/data/type"}

  defp fetch_data(_params, _type),
    do: {:error, 400, "Bad Request", "data with a type is required", "/data"}

  defp board(%{"attributes" => %{"board" => %{} = board}}) do
    case Board.new(board["columns"], board["rows"], square_m(board["squareMm"])) do
      {:ok, board} -> {:ok, board}
      {:error, reason} -> {:error, 422, "Invalid board", reason, "/data/attributes/board"}
    end
  end

  defp board(_data),
    do:
      {:error, 422, "Invalid board", "board with columns, rows and squareMm is required",
       "/data/attributes/board"}

  defp square_m(square_mm) when is_number(square_mm), do: square_mm / 1000
  defp square_m(_square_mm), do: nil
end
