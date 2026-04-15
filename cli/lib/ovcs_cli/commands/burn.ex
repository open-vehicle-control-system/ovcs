defmodule OvcsCli.Commands.Burn do
  @moduledoc "Burn firmware to an SD card for a vehicle/application."

  def run(repo_root, vehicle_dir, application) do
    OvcsCli.Commands.Firmware.dispatch!(repo_root, vehicle_dir, application, "./burn.sh")
  end
end
