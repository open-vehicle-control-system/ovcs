defmodule OvcsCli.Commands.Clean do
  @moduledoc "Remove build artifacts for a vehicle/application."

  def run(repo_root, vehicle_dir, application) do
    OvcsCli.Commands.Firmware.dispatch!(repo_root, vehicle_dir, application, "./clean.sh")
  end
end
