defmodule VisionApiWeb.CalibrationUnit do
  @moduledoc """
  The stereo unit the calibration routes and channel work on: the active
  `VisionCore.Config` and the unit's prefix, which names its calibration
  files.
  """

  @doc "The active configuration and the stereo unit's prefix, or `:error` without a `:stereo` component."
  @spec fetch() :: {:ok, VisionCore.Config.t(), String.t()} | :error
  def fetch do
    with %VisionCore.Config{} = config <- VisionCore.Application.active_config(),
         {:ok, cameras} <- VisionCore.Stereo.Supervisor.camera_options(config) do
      {:ok, config, cameras[:prefix]}
    else
      _no_stereo_unit -> :error
    end
  end
end
