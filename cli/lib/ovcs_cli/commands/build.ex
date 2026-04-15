defmodule OvcsCli.Commands.Build do
  @moduledoc "Build firmware for a vehicle/application."

  def run(repo_root, vehicle_dir, application) do
    OvcsCli.Commands.Firmware.dispatch!(repo_root, vehicle_dir, application, "./build.sh")
  end
end
