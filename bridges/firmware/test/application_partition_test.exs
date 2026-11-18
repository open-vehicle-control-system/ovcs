defmodule BridgeFirmware.ApplicationPartitionTest do
  use ExUnit.Case, async: true

  # The base CAN systems' erlinit mounts the application partition at `/root`, which `/data`
  # links to: Nerves Runtime finds it mounted only under that path, and formats it otherwise.
  # The config branches on `Mix.target/0`, which a config reader cannot set, so its source is read.
  test "leaves the application partition where the systems mount it" do
    refute File.read!(Path.expand("../config/config.exs", __DIR__)) =~ ~r/:erlinit, mount:/
    refute File.read!(Path.expand("../build.sh", __DIR__)) =~ "NERVES_FW_APPLICATION_PART0_TARGET"
  end
end
