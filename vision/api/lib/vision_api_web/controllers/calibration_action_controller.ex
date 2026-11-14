defmodule VisionApiWeb.CalibrationActionController do
  @moduledoc """
  The calibration session's actions and the return to a built-in
  calibration, created as action resources that answer with the session
  after the action. A session and a reset name their target, one of the
  `calibrations`, as their `calibration` relationship. The action is read
  from the JSON body only: a form or a query string, which another site's
  page can send without asking, is refused.

  A solve and an apply answer 202 once they have begun, with the session
  `solving` or `applying`; their outcome comes through the `calibration`
  channel.

  A reset the target refuses, as one with nothing stored, is a 422; one
  the unit fails, its stored calibration kept, a 500.
  """
  use VisionApiWeb, :controller
  require Logger

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Calibration.{Board, Session}

  @target_pointer "/data/relationships/calibration"
  @max_square_mm round(Board.max_square_m() * 1000)

  def start(conn, _params) do
    act(conn, "calibration-sessions", :created, fn data ->
      with {:ok, id} <- target(data),
           {:ok, board} <- board(data) do
        case Session.start(id, board) do
          :ok -> :ok
          {:error, :not_found} -> not_found(id)
          {:error, reason} -> {:error, start_status(), reason, [title: "Not started"]}
        end
      end
    end)
  end

  def cancel(conn, _params) do
    act(conn, "calibration-cancels", :created, fn _data ->
      refused(Session.cancel(), 409, "Not cancelled")
    end)
  end

  def solve(conn, _params) do
    act(conn, "calibration-solves", :accepted, fn _data ->
      refused(Session.solve(), 422, "Not solved")
    end)
  end

  def apply(conn, _params) do
    act(conn, "calibration-applies", :accepted, fn _data ->
      refused(Session.apply(), 422, "Not applied")
    end)
  end

  def reset(conn, _params) do
    act(conn, "calibration-resets", :created, fn data ->
      with {:ok, id} <- target(data) do
        config = CalibrationUnit.config()
        resettable? = match?({:ok, %{can_reset: true}}, Calibration.in_use(config, id))

        case reset_task(config, id) do
          {:error, :not_found} -> not_found(id)
          {:error, reason} when resettable? -> {:error, 500, reason, []}
          outcome -> refused(outcome, 422, "Not reset")
        end
      end
    end)
  end

  # Outlives the request: a reset may wait for the stereo unit to restart.
  defp reset_task(config, id) do
    task =
      Task.Supervisor.async_nolink(Calibration.Tasks, fn -> Calibration.reset(config, id) end)

    case Task.yield(task, :infinity) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        Logger.error("#{__MODULE__} reset failed: #{Exception.format_exit(reason)}")
        {:failed, "the reset failed; the log says why"}
    end
  end

  defp act(conn, type, status, run) do
    with :ok <- check_unit(),
         {:ok, data} <- fetch_data(JsonApi.document(conn), type),
         :ok <- run.(data) do
      id = Integer.to_string(System.unique_integer([:positive, :monotonic]))

      conn
      |> put_status(status)
      |> render(:show, type: type, id: id, session: Session.state())
    else
      {:error, status, detail, options} -> JsonApi.error(conn, status, detail, options)
    end
  end

  defp check_unit do
    cond do
      CalibrationUnit.targets() == [] ->
        {:error, 404, "the unit has nothing to calibrate: no stereo pair nor camera", []}

      GenServer.whereis(Session) == nil ->
        {:error, 503, "the calibration session is not running",
         [title: "Calibration unavailable"]}

      true ->
        :ok
    end
  end

  defp refused(:ok, _status, _title), do: :ok
  defp refused({:failed, reason}, _status, _title), do: {:error, 500, reason, []}
  defp refused({:error, reason}, status, title), do: {:error, status, reason, [title: title]}

  defp not_found(id), do: {:error, 404, "no calibration #{id}", [source: @target_pointer]}

  defp start_status, do: if(Session.state().phase == :idle, do: 422, else: 409)

  defp fetch_data(%{"data" => %{"type" => type, "id" => _id}}, type),
    do: JsonApi.client_id_refusal()

  defp fetch_data(%{"data" => %{"type" => type} = data}, type), do: {:ok, data}

  defp fetch_data(%{"data" => %{"type" => _other}}, type),
    do: {:error, 409, "type must be #{type}", [source: "/data/type"]}

  defp fetch_data(_params, _type),
    do: {:error, 400, "data with a type is required", [source: "/data"]}

  defp target(%{
         "relationships" => %{
           "calibration" => %{"data" => %{"type" => "calibrations", "id" => id}}
         }
       })
       when is_binary(id),
       do: {:ok, id}

  defp target(_data),
    do: {:error, 400, "calibration must name one of the calibrations", [source: @target_pointer]}

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
