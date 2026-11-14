defmodule VisionFirmware.ShoehornHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VisionFirmware.ShoehornHandler

  # A handler whose restarts and clock are the test's: `restart` tells the test, `now` reads `clock`.
  defp handler(options \\ []) do
    test = self()
    clock = start_supervised!({Agent, fn -> 0 end})

    {:ok, state} =
      ShoehornHandler.init(
        [
          restart: fn delay_ms, application -> send(test, {:restart, delay_ms, application}) end,
          now_ms: fn -> Agent.get(clock, & &1) end
        ] ++ options
      )

    {state, clock}
  end

  defp exited(state, application) do
    {{reaction, state}, _log} =
      with_log(fn -> ShoehornHandler.application_exited(application, :shutdown, state) end)

    {reaction, state}
  end

  test "restarts the firmware's applications a second after the vision core exits" do
    {state, _clock} = handler()

    assert {:continue, _state} = exited(state, :vision_core)
    assert_received {:restart, 1_000, :vision_firmware}
  end

  test "restarts them after the API exits too, and after the firmware's own application" do
    {state, _clock} = handler()

    assert {:continue, state} = exited(state, :vision_api)
    assert_received {:restart, 1_000, :vision_firmware}

    assert {:continue, _state} = exited(state, :vision_firmware)
    assert_received {:restart, 2_000, :vision_firmware}
  end

  test "leaves any other application that exits alone" do
    {state, _clock} = handler()

    assert {:continue, ^state} = exited(state, :nerves_hub_link)
    refute_received {:restart, _delay_ms, _application}
  end

  test "leaves an application stopped on purpose down" do
    {state, _clock} = handler()

    assert {:continue, ^state} = ShoehornHandler.application_exited(:vision_core, :stopped, state)
    refute_received {:restart, _delay_ms, _application}
  end

  test "waits twice as long before each restart, a minute at most" do
    {state, _clock} = handler()

    {_state, delays} =
      Enum.reduce(1..8, {state, []}, fn _exit, {state, delays} ->
        {:continue, state} = exited(state, :vision_core)
        assert_received {:restart, delay_ms, :vision_firmware}
        {state, delays ++ [delay_ms]}
      end)

    assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]
  end

  test "keeps restarting the applications, a minute apart, however many times they exit" do
    {state, _clock} = handler()

    state =
      Enum.reduce(1..50, state, fn _exit, state ->
        assert {:continue, state} = exited(state, :vision_core)
        assert_received {:restart, _delay_ms, :vision_firmware}
        state
      end)

    assert {:continue, _state} = exited(state, :vision_core)
    assert_received {:restart, 60_000, :vision_firmware}
  end

  test "waits a second again once the applications ran for the stable time" do
    {state, clock} = handler(stable_ms: 10_000)

    {:continue, state} = exited(state, :vision_core)
    {:continue, state} = exited(state, :vision_core)
    assert_received {:restart, 1_000, :vision_firmware}
    assert_received {:restart, 2_000, :vision_firmware}

    Agent.update(clock, fn _now -> 12_001 end)

    assert {:continue, _state} = exited(state, :vision_core)
    assert_received {:restart, 1_000, :vision_firmware}
  end

  test "the time a restart waits does not count as running" do
    {state, clock} = handler(stable_ms: 10_000)

    {:continue, state} = exited(state, :vision_core)
    {:continue, state} = exited(state, :vision_core)
    Agent.update(clock, fn _now -> 11_000 end)

    assert {:continue, _state} = exited(state, :vision_core)
    assert_received {:restart, 4_000, :vision_firmware}
  end

  test "says in the log which application exited, why, and when it restarts it" do
    {state, _clock} = handler()

    log = capture_log(fn -> ShoehornHandler.application_exited(:vision_core, :boom, state) end)
    assert log =~ "vision_core exited (:boom)"
    assert log =~ "restarting in 1000 ms"
    refute log =~ "rebooting"
  end

  test "starts with shoehorn's own options, which name no restart of the test's" do
    assert {:ok, _state} = ShoehornHandler.init(init: [:nerves_runtime], handler: ShoehornHandler)
  end
end
