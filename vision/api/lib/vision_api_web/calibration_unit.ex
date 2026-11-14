defmodule VisionApiWeb.CalibrationUnit do
  @moduledoc """
  What the calibration routes and channel work on: the active
  `VisionCore.Config` and the targets it can calibrate
  (`VisionCore.Calibration.targets/1`).
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
  The id of a calibration kept, from its text as the unit writes it:
  digits without a sign nor a leading zero. `:error` for any other text,
  which names no calibration.
  """
  @spec saved_id(String.t()) :: {:ok, pos_integer()} | :error
  def saved_id(text) do
    if Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, text),
      do: {:ok, String.to_integer(text)},
      else: :error
  end

  @doc """
  Refuses, under `title`, a change of the calibration in force while a
  calibration session runs: its apply would replace the change.
  """
  @spec check_idle(String.t()) :: :ok | VisionApiWeb.JsonApi.refusal()
  def check_idle(title) do
    case GenServer.whereis(Session) && Session.state().phase do
      phase when phase in [nil, :idle] -> :ok
      _running -> {:error, 409, "a calibration session is running", [title: title]}
    end
  end
end
