defmodule VmsCore.Components.OVCS.ControlStatusTest do
  @moduledoc """
  The control status frame follows the manager and the sources it names.
  Driven through `handle_info/2`; `init/1` configures a CAN emitter,
  which is not under test.
  """
  use ExUnit.Case, async: true
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.ControlStatus

  @manager ControlLevelManager

  defp receive_messages(state, messages) do
    Enum.reduce(messages, state, fn message, state ->
      {:noreply, state} = ControlStatus.handle_info(message, state)
      state
    end)
  end

  defp from_manager(name, value), do: %Message{name: name, value: value, source: @manager}

  test "reports the manager's level, commander and force" do
    state =
      @manager
      |> ControlStatus.initial_state()
      |> receive_messages([
        from_manager(:selected_control_level, :ros),
        from_manager(:selected_ros_commander, :autonomous),
        from_manager(:control_level_forced, true)
      ])

    assert %{
             "control_level" => "ros",
             "ros_commander" => "autonomous",
             "control_level_forced" => true
           } = ControlStatus.frame_data(state)
  end

  test "reports the requests of the named sources only" do
    state =
      @manager
      |> ControlStatus.initial_state()
      |> receive_messages([
        from_manager(:requested_throttle_source, Joystick),
        from_manager(:requested_steering_source, Joystick),
        %Message{name: :requested_throttle, value: D.new("0.4"), source: Joystick},
        %Message{name: :requested_steering, value: D.new("-0.2"), source: Joystick},
        %Message{name: :requested_throttle, value: D.new("0.9"), source: Radio}
      ])

    frame_data = ControlStatus.frame_data(state)
    assert D.eq?(frame_data["requested_throttle"], D.new("0.4"))
    assert D.eq?(frame_data["requested_steering"], D.new("-0.2"))
  end

  test "a request reads zero once its source changes, until the new one reports" do
    state =
      @manager
      |> ControlStatus.initial_state()
      |> receive_messages([
        from_manager(:requested_throttle_source, Joystick),
        %Message{name: :requested_throttle, value: D.new("0.4"), source: Joystick},
        from_manager(:requested_throttle_source, Joystick),
        from_manager(:requested_throttle_source, nil),
        %Message{name: :requested_throttle, value: D.new("0.4"), source: nil}
      ])

    assert D.eq?(ControlStatus.frame_data(state)["requested_throttle"], D.new(0))
  end

  test "a source reporting no request reads zero" do
    state =
      @manager
      |> ControlStatus.initial_state()
      |> receive_messages([
        from_manager(:requested_steering_source, Joystick),
        %Message{name: :requested_steering, value: nil, source: Joystick}
      ])

    assert D.eq?(ControlStatus.frame_data(state)["requested_steering"], D.new(0))
  end

  test "the frame definition is valid for emitting" do
    path = Path.join(:code.priv_dir(:ovcs_can), "can/components/ovcs/0x60C_control_status.yml")
    {:ok, yaml} = YamlElixir.read_from_file(path, atoms: true)
    frame = yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms)

    assert {:ok, _} = Cantastic.FrameSpecification.from_yaml(:ovcs, frame, :emit)
  end
end
