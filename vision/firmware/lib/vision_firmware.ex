defmodule VisionFirmware do
  @moduledoc """
  Nerves firmware for a vehicle's vision unit: `vision_api` and
  `vision_core` on a Raspberry Pi 5 or an OKdo Nano C100.
  """

  @doc """
  The `wifi:` mode of `composer`'s target config, which `config/runtime.exs`
  hands to `OvcsVehicle.Wifi`; `:join` when the composer cannot build its
  config, so that a broken composer leaves the unit reachable.
  """
  @spec wifi_mode(module()) :: OvcsVehicle.Wifi.mode()
  def wifi_mode(composer) do
    composer.config(:target).wifi
  rescue
    _error -> :join
  end

  @doc """
  `{:error, message}` when `composer` hosts a hotspot and `psk`, the
  vehicle's `WIFI_HOTSPOT_PSK`, is no passphrase WPA2 takes: the release
  refuses such a build, whose unit would boot with its Wi-Fi off.
  """
  @spec check_wifi(module(), String.t() | nil) :: :ok | {:error, String.t()}
  def check_wifi(composer, psk) do
    case wifi_mode(composer) do
      {:hotspot, _hotspot} ->
        if OvcsVehicle.Wifi.valid_passphrase?(psk),
          do: :ok,
          else:
            {:error,
             "#{inspect(composer)} hosts a hotspot: set WIFI_HOTSPOT_PSK in the vehicle's .env.exs, " <>
               "8 to 63 printable ASCII characters"}

      _mode ->
        :ok
    end
  end

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
        note: "open http://localhost:5174, not :4101"
      }
    ]
  end
end
