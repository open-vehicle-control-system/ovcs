defmodule VmsFirmware do
  @moduledoc """
  Documentation for VmsFirmware.
  """

  @doc """
  Dev-time add-ons started by `./ovcs run` alongside this firmware's BEAM
  on host runs (not on a deployed target, where the dashboard is bundled
  into the firmware image instead).

  Each entry is a companion process the CLI launches generically:

    * `:name` — short id, unique within this firmware (log prefix suffix).
    * `:dir` — working directory, relative to this firmware project.
    * `:run` — argv of the long-running dev process.
    * `:install` — optional argv run once when `:ready_marker` is absent.
    * `:ready_marker` — optional path under `:dir`; present ⇒ deps installed.
    * `:note` — optional one-line hint shown when it starts.

  The VMS dashboard (`vms/dashboard`, a Vue/Vite app) runs as a live dev
  server so `.vue` edits hot-reload without rebuilding the static bundle.
  """
  def dev_addons do
    [
      %{
        name: "dashboard",
        dir: "../dashboard",
        run: ["npm", "run", "dev"],
        install: ["npm", "install"],
        ready_marker: "node_modules",
        note: "open the dev URL it logs (usually http://localhost:5173), not :4000"
      }
    ]
  end
end
