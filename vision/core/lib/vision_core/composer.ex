defmodule VisionCore.Composer do
  @moduledoc """
  What a vehicle package provides to `VisionCore`: which components run
  and how they are configured.
  """

  @doc """
  The vision config for the active arm: `:host` on a workstation,
  `:target` on the vision firmware.
  """
  @callback config(arm :: :host | :target) :: VisionCore.Config.t()

  @doc "Paths, relative to the vehicle app, that the vision firmware ships."
  @callback required_files() :: [String.t()]

  @optional_callbacks required_files: 0
end
