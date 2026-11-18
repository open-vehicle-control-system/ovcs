defmodule BridgeFirmware.LoggerTest do
  use ExUnit.Case, async: true

  # A board's log is RingLogger's buffer: at debug, or at its default 1024 entries, the boot's
  # messages are gone within minutes. The config branches on `Mix.target/0`, which a config
  # reader cannot set, so its source is read.
  test "keeps the board's info messages, 8192 of them" do
    config = File.read!(Path.expand("../config/config.exs", __DIR__))

    assert config =~ "config :logger, backends: [RingLogger], level: :info"
    assert config =~ "config :logger, RingLogger, max_size: 8192"
  end
end
