defmodule VmsFirmware.ApplicationPartitionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "early boot mounts the pinned RPi4 system's application partition at /data" do
    overrides = %{
      "VEHICLE" => "VmsMountContractTest",
      "CI" => "true",
      "WIFI_NETWORKS" => nil,
      "NERVES_HUB_HOST" => nil
    }

    previous = Map.new(overrides, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(overrides)

    try do
      capture_io(:stderr, fn ->
        config =
          Config.Reader.read!(Path.expand("../config/target.exs", __DIR__),
            env: :test,
            target: :ovcs_base_can_system_rpi4
          )

        mount =
          config |> Keyword.fetch!(:nerves) |> Keyword.fetch!(:erlinit) |> Keyword.fetch!(:mount)

        # The pinned system's fwup-common.conf declares application data on p7.
        # p3 is BOOT-B, not an F2FS application partition.
        assert mount == "/dev/mmcblk0p7:/data:f2fs:nodev:"
      end)
    after
      System.put_env(previous)
    end
  end
end
