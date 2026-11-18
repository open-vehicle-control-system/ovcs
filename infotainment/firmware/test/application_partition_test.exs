defmodule InfotainmentFirmware.ApplicationPartitionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # The pinned system's erlinit mounts the application partition at `/root`, which `/data`
  # links to: Nerves Runtime finds it mounted only under that path, and formats it otherwise.
  test "leaves the application partition where the pinned system mounts it" do
    overrides = %{"VEHICLE" => "InfotainmentMountContractTest", "CI" => "true"}
    previous = Map.new(overrides, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(overrides)

    try do
      capture_io(:stderr, fn ->
        config =
          Config.Reader.read!(Path.expand("../config/target.exs", __DIR__),
            env: :test,
            target: :ovcs_base_can_system_rpi5
          )

        refute config
               |> Keyword.fetch!(:nerves)
               |> Keyword.fetch!(:erlinit)
               |> Keyword.has_key?(:mount)
      end)
    after
      System.put_env(previous)
    end

    refute File.read!(Path.expand("../build.sh", __DIR__)) =~ "NERVES_FW_APPLICATION_PART0_TARGET"
  end
end
