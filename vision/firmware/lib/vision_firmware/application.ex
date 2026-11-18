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
        OvcsVehicle.FirmwareValidator,
        OvcsVehicle.ClockSync,
        {OvcsVehicle.Wifi, wifi_options(VisionCore.Application.active_config())}
      ]
  end

  @doc """
  `OvcsVehicle.Wifi`'s options for `config`, the composer's: its `wifi:`
  mode, `:join` without a composer, with the networks and the hotspot
  passphrase of the vehicle's `.env.exs`.
  """
  @spec wifi_options(VisionCore.Config.t() | nil) :: keyword()
  def wifi_options(config) do
    [
      mode: if(config, do: config.wifi, else: :join),
      networks: Application.get_env(:vision_firmware, :wifi_networks, []),
      hotspot_psk: Application.get_env(:vision_firmware, :wifi_hotspot_psk)
    ]
  end
end
