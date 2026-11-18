defmodule InfotainmentFirmware.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # A board's log is RingLogger's buffer: at debug, or at its default 1024 entries, the boot's
  # messages are gone within minutes.
  test "keeps the board's info messages, 8192 of them" do
    overrides = %{
      "VEHICLE" => "InfotainmentMountContractTest",
      "CI" => "true",
      "WIFI_NETWORKS" => nil,
      "NERVES_HUB_HOST" => nil
    }

    previous = Map.new(overrides, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(overrides)

    try do
      capture_io(:stderr, fn ->
        logger =
          Config.Reader.read!(Path.expand("../config/target.exs", __DIR__),
            env: :test,
            target: :ovcs_base_can_system_rpi5
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
