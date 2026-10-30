defmodule VisionFirmware.Application do
  @moduledoc false
  use Application

  # The pipeline lives in `VisionCore.Application` and `VisionApi.Application`.
  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: VisionFirmware.Supervisor)
  end

  # See `OvcsVehicle.HostUEventGuard`, `OvcsVehicle.FirmwareValidator` and
  # `OvcsVehicle.CpuGovernor`; the GPU governor pins a devfreq GPU, such as
  # the C100's, where the stereo stages run.
  defp children do
    if Nerves.Runtime.mix_target() == :host,
      do: [OvcsVehicle.HostUEventGuard],
      else: [
        OvcsVehicle.CpuGovernor,
        Supervisor.child_spec(
          {OvcsVehicle.CpuGovernor, glob: "/sys/class/devfreq/*gpu*/governor"},
          id: :gpu_governor
        ),
        OvcsVehicle.FirmwareValidator
      ]
  end
end
