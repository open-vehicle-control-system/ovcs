defmodule VisionFirmware.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # A board's log is RingLogger's buffer: at its default 1024 entries, the pipelines' rate
  # lines push the boot's messages out within minutes.
  test "keeps the board's info messages, 8192 of them" do
    overrides = %{"VEHICLE" => "LoggerTestVehicle", "CI" => "true"}
    previous = Map.new(overrides, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(overrides)

    try do
      capture_io(:stderr, fn ->
        logger =
          Config.Reader.read!(Path.expand("../config/target.exs", __DIR__),
            env: :test,
            target: :rpi5
          )
          |> Keyword.fetch!(:logger)

        assert logger[:level] == :info
        assert logger[RingLogger][:max_size] == 8192
      end)
    after
      System.put_env(previous)
    end
  end
end
