defmodule VisionApiWeb.CalibrationUnit do
  @moduledoc """
  What the calibration routes and channel work on: the active
  `VisionCore.Config` and the targets it can calibrate
  (`VisionCore.Calibration.targets/1`), and the refusals the routes send
  for the unit's answers.
  """

  require Logger

  alias VisionCore.Calibration.Session

  @doc "The active configuration, an empty one while the vision core runs none."
  @spec config() :: VisionCore.Config.t()
  def config, do: VisionCore.Application.active_config() || %VisionCore.Config{}

  @doc "The targets the unit can calibrate, none while the vision core runs no configuration."
  @spec targets() :: [VisionCore.Calibration.target()]
  def targets, do: VisionCore.Calibration.targets(config())

  @saved_unavailable "saved calibrations unavailable"

  @doc """
  Whether `reason`, a refusal of `VisionCore.Calibration`, says its
  database cannot be reached, as `VisionCore.Calibration.Library` words it.
  """
  @spec saved_unavailable?(term()) :: boolean()
  def saved_unavailable?(reason), do: reason in [:unavailable, @saved_unavailable]

  @doc "The refusal `VisionApiWeb.JsonApi.error/4` sends while that database cannot be reached."
  @spec saved_unavailable() :: VisionApiWeb.JsonApi.refusal()
  def saved_unavailable,
    do: {:error, 503, @saved_unavailable, [title: "Saved calibrations unavailable"]}

  @doc """
  Runs `work`, a commit or a reset of a calibration, under
  `VisionCore.Calibration.Tasks` and waits for it: `{:ok, outcome}`, or
  `:failed` once its exit is logged as that of `what`. The work outlives
  the request: a stereo pair's may wait for its unit to restart.
  """
  @spec run(String.t(), (-> outcome)) :: {:ok, outcome} | :failed when outcome: term()
  def run(what, work) do
    task = Task.Supervisor.async_nolink(VisionCore.Calibration.Tasks, work)

    case Task.yield(task, :infinity) do
      {:ok, outcome} ->
        {:ok, outcome}

      {:exit, reason} ->
        Logger.error("#{what} failed: #{Exception.format_exit(reason)}")
        :failed
    end
  end

  @doc """
  The id of a saved calibration, from its text as the unit writes it: a
  UUID in lower case, with its hyphens. `:error` for any other text,
  which names no calibration.
  """
  @spec saved_id(String.t()) :: {:ok, String.t()} | :error
  def saved_id(text) do
    case Ecto.UUID.cast(text) do
      {:ok, ^text} -> {:ok, text}
      _other -> :error
    end
  end

  @doc """
  Refuses, under `title`, a change of the calibration in use while a
  calibration session runs: its apply would replace the change.
  """
  @spec check_idle(String.t()) :: :ok | VisionApiWeb.JsonApi.refusal()
  def check_idle(title) do
    case GenServer.whereis(Session) && Session.state().phase do
      phase when phase in [nil, :idle] -> :ok
      _running -> {:error, 409, "a calibration session is running", [title: title]}
    end
  end

  @target_pointer "/data/relationships/calibration"

  @doc """
  Refuses a calibration action on a unit with nothing to calibrate, a
  404, and while `VisionCore.Calibration.Session` does not run, a 503.
  """
  @spec check_session() :: :ok | VisionApiWeb.JsonApi.refusal()
  def check_session do
    cond do
      targets() == [] ->
        {:error, 404, "the unit has nothing to calibrate: no stereo pair nor camera", []}

      GenServer.whereis(Session) == nil ->
        {:error, 503, "the calibration session is not running",
         [title: "Calibration unavailable"]}

      true ->
        :ok
    end
  end

  @doc """
  The id of the calibration `data`, a write's resource object, names as
  its `calibration` relationship, or the 400 without one.
  """
  @spec fetch_target_id(term()) :: {:ok, String.t()} | VisionApiWeb.JsonApi.refusal()
  def fetch_target_id(%{
        "relationships" => %{
          "calibration" => %{"data" => %{"type" => "calibrations", "id" => id}}
        }
      })
      when is_binary(id),
      do: {:ok, id}

  def fetch_target_id(_data),
    do: {:error, 400, "calibration must name one of the calibrations", [source: @target_pointer]}

  @doc "The 404 for `id`, a calibration the unit has not, named as a `calibration` relationship."
  @spec target_not_found(String.t()) :: VisionApiWeb.JsonApi.refusal()
  def target_not_found(id),
    do: {:error, 404, "no calibration #{id}", [source: @target_pointer]}

  @doc """
  `:ok` for `outcome`, an answer of the session or of a reset, of `:ok`;
  otherwise the refusal: a 500 for a failure of the unit, and `status`
  under `title` for a refusal.
  """
  @spec check_outcome(
          :ok | {:failed, String.t()} | {:error, String.t()},
          pos_integer(),
          String.t()
        ) ::
          :ok | VisionApiWeb.JsonApi.refusal()
  def check_outcome(:ok, _status, _title), do: :ok
  def check_outcome({:failed, reason}, _status, _title), do: {:error, 500, reason, []}

  def check_outcome({:error, reason}, status, title),
    do: {:error, status, reason, [title: title]}
end
