defmodule OvcsCli.Commands.Upload do
  @moduledoc "OTA-upload firmware to a running device."

  def run(repo_root, vehicle_dir, application, opts) do
    host = opts[:host] || default_host(vehicle_dir, application)
    cmd = "./upload.sh #{host}" <> if(opts[:file], do: " #{opts[:file]}", else: "")
    OvcsCli.Commands.Firmware.dispatch!(repo_root, vehicle_dir, application, cmd)
  end

  defp default_host(vehicle_dir, application) do
    dashed = String.replace(vehicle_dir, "_", "-")
    "#{dashed}-#{application}.local"
  end
end
