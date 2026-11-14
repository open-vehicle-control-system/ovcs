defmodule SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.IgnitionLockTest do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [read_back: 3]

  alias SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.IgnitionLock

  @emitted_key_status "can/components/volkswagen/polo_9n/simulated/0x570_key_status.yml"
  @shared_key_status "can/components/volkswagen/polo_9n/0x570_key_status.yml"

  defp init(steps),
    do: IgnitionLock.init(network: :polo_drive, steps: steps)

  # The key state the VMS decodes from what the lock reports at `now_ms`.
  defp key_state(state, now_ms) do
    {state, [{:polo_drive, "key_status", signals}]} = IgnitionLock.report(state, nil, now_ms)
    {state, read_back(signals, @emitted_key_status, @shared_key_status)["key_state"]}
  end

  defp vms_status(state, now_ms),
    do: IgnitionLock.handle_frame("vms_status", %{}, state, now_ms)

  test "reads the VMS's status and reports the key off from the start" do
    {_state, received, emitted} = init([])

    assert received == [{:ovcs, "vms_status"}]
    assert [{:polo_drive, "key_status", signals}] = emitted

    assert read_back(signals, @emitted_key_status, @shared_key_status)["key_state"] ==
             "contact_off"
  end

  test "the VMS reads each key position as it decodes the real lock's" do
    for {position, key_state} <- [off: "contact_off", on: "contact_on", start: "start_engine"] do
      {state, _received, _emitted} = init([{0, position}])
      state = vms_status(state, 0)
      assert {_state, ^key_state} = key_state(state, 0)
    end
  end

  test "the key stays off until the VMS is there, then follows the script" do
    {state, _received, _emitted} = init([{1_000, :start}, {2_000, :on}])

    assert {state, "contact_off"} = key_state(state, 5_000)
    state = vms_status(state, 10_000)
    assert {state, "contact_off"} = key_state(state, 10_500)
    state = vms_status(state, 10_900)
    assert {state, "start_engine"} = key_state(state, 11_000)
    state = vms_status(state, 11_900)
    assert {_state, "contact_on"} = key_state(state, 12_000)
  end

  test "a VMS that goes quiet turns the key back off and rewinds the script" do
    {state, _received, _emitted} = init([{0, :on}])
    state = vms_status(state, 0)
    assert {state, "contact_on"} = key_state(state, 500)

    assert {state, "contact_off"} = key_state(state, 2_000)
    state = vms_status(state, 3_000)
    assert {_state, "contact_on"} = key_state(state, 3_000)
  end
end
