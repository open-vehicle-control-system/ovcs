defmodule VmsCore.Managers.ControlLevelTest do
  @moduledoc """
  The manager decides who commands the vehicle, and it had no tests.

  Everything here drives `handle_info/2` directly against the state
  `init/1` builds, rather than starting the GenServer: the transitions
  are the subject, and a real process would need a CAN stack and a
  wall-clock loop to reach the same states.

  The two axes are tested separately and then together, because the
  point of splitting them is that neither can quietly move the other.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VmsCore.Managers.ControlLevel
  alias OvcsBus.Message
  alias Decimal, as: D

  @zero D.new(0)

  # Stand-ins for the real components. The manager only ever compares
  # these for equality and hands them on as `:requested_*_source`, so
  # what matters is that they are distinguishable.
  @args %{
    requested_control_level_source: RadioLevel,
    requested_ros_commander_source: RadioCommander,
    requested_gear_sources: %{manual: nil, radio: nil, ros: %{}},
    requested_direction_sources: %{manual: nil, radio: nil, ros: %{teleop: TeleopDirection}},
    requested_throttle_sources: %{
      manual: Pedal,
      radio: RadioThrottle,
      ros: %{teleop: TeleopThrottle, autonomous: PlannerVelocity}
    },
    requested_steering_sources: %{
      manual: nil,
      radio: RadioSteering,
      ros: %{teleop: TeleopSteering, autonomous: PlannerVelocity}
    },
    manual_breaking_source: BrakePedal,
    radio_breaking_source: RadioThrottle,
    default_control_level: :manual,
    ready_to_drive_source: Vms,
    speed_source: Abs
  }

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  defp manager(overrides \\ %{}) do
    {:ok, state} = ControlLevel.init(Map.merge(@args, overrides))
    # `init/1` arms a 10 ms interval that would race every assertion.
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    state
  end

  defp tick(state) do
    {:noreply, state} = ControlLevel.handle_info(:loop, state)
    state
  end

  defp deliver(state, name, value, source) do
    {:noreply, state} =
      ControlLevel.handle_info(%Message{name: name, value: value, source: source}, state)

    state
  end

  # The transmitter says "ready, stopped, and asking for this level".
  defp request(state, level) do
    state
    |> deliver(:ready_to_drive, true, Vms)
    |> deliver(:speed, @zero, Abs)
    |> deliver(:requested_control_level, level, RadioLevel)
    |> tick()
  end

  # `:ros` is only reachable from `:radio`, so getting there is two
  # deliberate steps rather than one.
  defp in_ros(state \\ manager()) do
    state |> request(:radio) |> request(:ros)
  end

  describe "the authority axis" do
    test "starts in the default level, with that level's sources" do
      state = manager()

      assert state.selected_control_level == :manual
      assert state.requested_throttle_source == Pedal
      assert state.requested_steering_source == nil
    end

    test "reaches :ros through :radio, and routes the sources with it" do
      state = manager() |> request(:radio)
      assert state.selected_control_level == :radio
      assert state.requested_throttle_source == RadioThrottle

      state = request(state, :ros)
      assert state.selected_control_level == :ros
      # Default commander, so the gamepad path -- not the planner.
      assert state.requested_throttle_source == TeleopThrottle
      assert state.requested_steering_source == TeleopSteering
    end

    test "refuses :ros straight from :manual, and says so once" do
      # The silent failure this exists for: a switch already in the top
      # position at boot fell through every branch and stayed in
      # :manual for ever without a word.
      state = manager()

      log =
        capture_log(fn ->
          send(self(), {:state, request(state, :ros)})
        end)

      assert_received {:state, state}
      assert state.selected_control_level == :manual
      assert log =~ ":ros"
      assert log =~ "ros_only_reachable_from_radio"

      # Held, not repeated: the loop runs at 100 Hz.
      assert capture_log(fn -> tick(state) end) == ""
    end

    test "a request that is already satisfied is not a refusal" do
      state = in_ros()
      assert capture_log(fn -> tick(state) end) == ""
    end
  end

  describe "the commander axis" do
    test "defaults to :teleop, so a planner never inherits the vehicle" do
      assert manager().selected_ros_commander == :teleop
      assert in_ros().requested_throttle_source == TeleopThrottle
    end

    test "arms :autonomous at a standstill" do
      state =
        in_ros()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()

      assert state.selected_ros_commander == :autonomous
      assert state.requested_throttle_source == PlannerVelocity
      assert state.requested_steering_source == PlannerVelocity
      # A velocity carries its own sign, so there is no direction source
      # on this path -- and a missing key must resolve to nil, not raise.
      assert state.requested_direction_source == nil
    end

    test "refuses to arm :autonomous while moving" do
      state =
        in_ros()
        |> deliver(:speed, D.new("2.5"), Abs)
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()

      assert state.selected_ros_commander == :teleop
      assert state.requested_throttle_source == TeleopThrottle
    end

    test "hands control back to :teleop immediately, even at speed" do
      # The asymmetry is the safety property: an operator reaching for
      # the switch because the planner is doing something wrong must not
      # be made to come to a stop first.
      state =
        in_ros()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()

      assert state.selected_ros_commander == :autonomous

      state =
        state
        |> deliver(:speed, D.new("2.5"), Abs)
        |> deliver(:requested_ros_commander, :teleop, RadioCommander)
        |> tick()

      assert state.selected_ros_commander == :teleop
      assert state.requested_throttle_source == TeleopThrottle
    end

    test "disarms when authority leaves :ros, so re-entry re-arms" do
      armed =
        in_ros()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()

      assert armed.selected_ros_commander == :autonomous

      # Authority taken away while the planner was driving.
      dropped = request(armed, :manual)
      assert dropped.selected_control_level == :manual
      assert dropped.selected_ros_commander == :teleop

      # Coming back does not resume the planner on the strength of a
      # switch that never moved: it goes through the standstill gate
      # again, which is where the interlock lives.
      assert dropped.requested_throttle_source == Pedal
    end

    test "is inert off the :ros level" do
      state =
        manager()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> request(:radio)

      assert state.selected_control_level == :radio
      assert state.selected_ros_commander == :teleop
      assert state.requested_throttle_source == RadioThrottle
    end

    test "a vehicle with no second switch stays in :teleop" do
      # OVCS1: no commander channel, and `ros:` populated for :teleop
      # only. The planner position must be unreachable rather than
      # resolving to nil and silently commanding nothing.
      state =
        manager(%{requested_ros_commander_source: nil})
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> in_ros()

      assert state.selected_ros_commander == :teleop
      assert state.requested_throttle_source == TeleopThrottle
    end
  end

  describe "the two axes together" do
    test "the radio brake drops :ros to :radio whichever commander was driving" do
      state =
        in_ros()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()

      assert state.requested_throttle_source == PlannerVelocity

      state = state |> deliver(:radio_breaking, true, RadioThrottle) |> tick()

      assert state.selected_control_level == :radio
      assert state.forced_control_level == :radio
      assert state.requested_throttle_source == RadioThrottle
      assert state.selected_ros_commander == :teleop
    end

    test "a fault forces :manual out of an autonomous drive" do
      state =
        in_ros()
        |> deliver(:requested_ros_commander, :autonomous, RadioCommander)
        |> tick()
        |> deliver(:ready_to_drive, false, Vms)
        |> tick()

      assert state.selected_control_level == :manual
      assert state.forced_control_level == :manual
      assert state.selected_ros_commander == :teleop
    end
  end

  describe "source attribution" do
    test "an unattributed message never reaches the bus" do
      # The handlers gate on `source == state.speed_source`, and the bus
      # is cluster-wide, so a nil-source message would read as a
      # wildcard on any vehicle that leaves that source unconfigured --
      # which OVCS Mini does for three of them. The bus refuses it
      # instead, so the manager never has to consider the case.
      assert_raise ArgumentError, ~r/has no :source/, fn ->
        OvcsBus.broadcast("messages", %Message{name: :speed, value: D.new("9.9"), source: nil})
      end

      refute_receive %Message{name: :speed}, 50
    end
  end

  describe "what it publishes" do
    test "the selected commander, so a dashboard can show which one has it" do
      in_ros() |> deliver(:requested_ros_commander, :autonomous, RadioCommander) |> tick()

      assert_receive %Message{
        name: :selected_ros_commander,
        value: :autonomous,
        source: ControlLevel
      }

      assert_receive %Message{name: :selected_control_level, value: :ros, source: ControlLevel}

      assert_receive %Message{
        name: :requested_throttle_source,
        value: PlannerVelocity,
        source: ControlLevel
      }
    end
  end

  describe "source map validation" do
    test "a flat :ros entry is refused at init rather than on the first flip to :ros" do
      args = %{@args | requested_throttle_sources: %{manual: nil, radio: nil, ros: Planner}}

      assert_raise ArgumentError, ~r/requested_throttle_sources.*:ros.*keyed by commander/s, fn ->
        ControlLevel.init(args)
      end
    end

    test "an :autonomous level is refused, naming the rename" do
      args = %{
        @args
        | requested_steering_sources: %{manual: nil, radio: nil, autonomous: Planner}
      }

      assert_raise ArgumentError, ~r/requested_steering_sources.*:autonomous.*:ros/s, fn ->
        ControlLevel.init(args)
      end
    end

    test "a :ros entry without every commander is fine: a missing key commands nothing" do
      state = manager(%{requested_throttle_sources: %{manual: nil, radio: nil, ros: %{}}})
      assert is_map(state)
    end
  end
end
