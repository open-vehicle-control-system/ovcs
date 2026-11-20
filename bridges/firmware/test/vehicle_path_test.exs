defmodule BridgeFirmware.VehiclePathTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @firmware_dir Path.expand("..", __DIR__)

  # A vehicle kept in its own repository is found at OVCS_VEHICLE_PATH, not under vehicles/.
  @tag :tmp_dir
  test "a vehicle at OVCS_VEHICLE_PATH supplies its firmware files and its .env.exs", %{
    tmp_dir: vehicle
  } do
    overrides = Path.join(vehicle, "priv/firmware/bridges/ros")
    File.mkdir_p!(overrides)
    File.write!(Path.join(overrides, "fwup.conf"), "")
    File.write!(Path.join(overrides, "config.txt"), "")

    File.write!(
      Path.join(vehicle, ".env.exs"),
      ~s(System.put_env("VEHICLE_PATH_TEST_ENV", "read"\)\n)
    )

    with_env(
      %{
        "VEHICLE" => "VehiclePathTest",
        "OVCS_VEHICLE_PATH" => vehicle,
        "CI" => "true",
        "VEHICLE_PATH_TEST_ENV" => nil,
        "VEHICLE_FIRMWARE_DIR" => nil,
        "WIFI_NETWORKS" => nil,
        "NERVES_HUB_HOST" => nil,
        "BRIDGE_FIRMWARE_ID" => "ros"
      },
      fn ->
        config =
          read_config(:ovcs_base_can_system_rpi4)

        fwup_conf =
          config
          |> Keyword.fetch!(:nerves)
          |> Keyword.fetch!(:firmware)
          |> Keyword.fetch!(:fwup_conf)

        assert Path.expand(fwup_conf, @firmware_dir) == Path.join(overrides, "fwup.conf")
        assert System.get_env("VEHICLE_FIRMWARE_DIR") == overrides
        assert System.get_env("VEHICLE_PATH_TEST_ENV") == "read"
      end
    )
  end

  # The configs branch on Mix.target(), which Config.Reader's :target option leaves alone.
  defp read_config(target) do
    host = Mix.target()
    Mix.target(target)

    try do
      Config.Reader.read!(Path.join(@firmware_dir, "config/config.exs"),
        env: :test,
        target: target
      )
    after
      Mix.target(host)
    end
  end

  defp with_env(overrides, fun) do
    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)
    put_env(overrides)

    try do
      capture_io(:stderr, fun)
    after
      put_env(previous)
    end
  end

  defp put_env(values) do
    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
