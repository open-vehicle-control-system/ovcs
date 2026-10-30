defmodule VisionFirmware do
  @moduledoc """
  Nerves firmware for a vehicle's vision unit: `vision_api` and
  `vision_core` on a Raspberry Pi 5.
  """

  @doc """
  Dev-time add-ons started by `./ovcs run` alongside this firmware's BEAM
  on host runs, in the entry format of `vms/firmware`'s `dev_addons/0`.

  The vision dashboard (`vision/dashboard`, a React/Vite app) runs as a live
  dev server so `.jsx` edits hot-reload without rebuilding the static
  bundle.
  """
  def dev_addons do
    [
      %{
        name: "dashboard",
        dir: "../dashboard",
        run: ["npm", "run", "dev"],
        install: ["npm", "install"],
        ready_marker: "node_modules",
        note: "open http://localhost:5174, not :4100"
      }
    ]
  end
end
