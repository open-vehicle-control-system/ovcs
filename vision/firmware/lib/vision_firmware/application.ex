defmodule VisionFirmware.Application do
  @moduledoc false
  use Application

  # The pipeline lives in `VisionCore.Application` and `VisionApi.Application`.
  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: VisionFirmware.Supervisor)
  end

  # The second governor pins the devfreq GPU the stereo stages run on, once its driver probes.
  defp children do
    if Nerves.Runtime.mix_target() == :host,
      do: [OvcsVehicle.HostUEventGuard],
      else: [
        OvcsVehicle.CpuGovernor,
        Supervisor.child_spec(
          {OvcsVehicle.CpuGovernor,
           glob: "/sys/class/devfreq/*gpu*/governor", devices: "GPU", await: 60_000},
          id: :gpu_governor
        ),
        OvcsVehicle.FirmwareValidator
      ]
  end
end
