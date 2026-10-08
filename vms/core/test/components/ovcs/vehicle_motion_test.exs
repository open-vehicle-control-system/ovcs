defmodule VmsCore.Components.OVCS.VehicleMotionTest do
  @moduledoc """
  The motion frame's claims: the kinematics turn a shaft's rotation
  into the vehicle's speed, the sign follows the command unless the
  source knows it, and an unknown rotation is flagged rather than
  encoded as a standstill.

  Driven through `handle_info/2` against a stub state, the way the
  actuator tests do — `init/1` configures a CAN emitter, which is not
  under test. The constants are the Mini's: a 0.0548 m wheel and a
  sensed shaft geared 2.72:1 to it.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.VehicleMotion

  @manager ControlLevelManager
  @sensor ShaftSensor
  @commander SomeCommander
  @ratio 2.72
  @wheel_radius 0.0548

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        rotation_source: @sensor,
        rotation_signed: false,
        rotation_to_wheel_ratio: D.from_float(@ratio),
        speed_factor: VehicleMotion.speed_factor(@ratio, @wheel_radius),
        selected_control_level_source: @manager,
        steering_factor: D.from_float(0.52),
        requested_throttle_source: @commander,
        requested_steering_source: @commander,
        direction_sign: 1,
        requested_steering: D.new(0),
        rotation_per_minute: nil,
        revolution_source: @sensor,
        distance_factor: VehicleMotion.distance_factor(@ratio, @wheel_radius),
        revolutions: nil,
        sequence: 0
      },
      overrides
    )
  end

  describe "the kinematics" do
    test "one wheel turn per second" do
      # 2.72 shaft turns per wheel turn: 163.2 shaft rpm is 60 wheel
      # rpm, 2π · 0.0548 m = 0.3443 m/s = 1.24 km/h.
      state = state(%{rotation_per_minute: D.new("163.2")})
      assert D.eq?(VehicleMotion.speed_km_h(state), D.new("1.24"))
      assert D.eq?(VehicleMotion.wheel_rotation_per_minute(state), D.new("60.0"))
    end

    test "no rotation is exactly zero, which is what the standstill gate needs" do
      state = state(%{rotation_per_minute: D.new(0)})
      assert D.eq?(VehicleMotion.speed_km_h(state), D.new(0))
      assert D.eq?(VehicleMotion.wheel_rotation_per_minute(state), D.new(0))
    end

    test "the sensed shaft is not the wheel" do
      # A shaft geared 2.72:1 turns 2.72 times per wheel turn, so the
      # same rpm on it is a slower vehicle than on the wheel itself.
      on_shaft = state(%{rotation_per_minute: D.new("100.0")})

      on_wheel =
        state(%{
          rotation_per_minute: D.new("100.0"),
          rotation_to_wheel_ratio: D.new(1),
          speed_factor: VehicleMotion.speed_factor(1, @wheel_radius)
        })

      assert D.lt?(VehicleMotion.speed_km_h(on_shaft), VehicleMotion.speed_km_h(on_wheel))
    end

    test "km/h to m/s for the frame" do
      # 3.6 km/h is 1 m/s.
      assert D.eq?(VehicleMotion.speed_m_s(D.new("3.6")), D.new("1.000"))
      assert D.eq?(VehicleMotion.speed_m_s(D.new("-3.6")), D.new("-1.000"))
    end
  end

  describe "the direction sign" do
    test "follows the sign of the selected throttle request" do
      assert VehicleMotion.direction_sign(D.new("0.4"), -1) == 1
      assert VehicleMotion.direction_sign(D.new("-0.4"), 1) == -1
    end

    test "a zero throttle keeps the last sign: coasting is not a direction change" do
      assert VehicleMotion.direction_sign(D.new(0), -1) == -1
      assert VehicleMotion.direction_sign(D.new(0), 1) == 1
    end

    test "only the selected commander moves it" do
      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_throttle, value: D.new("-1"), source: Impostor},
          state()
        )

      assert unchanged.direction_sign == 1
    end

    test "an unsigned rotation takes the command's sign" do
      state = state(%{rotation_per_minute: D.new("163.2"), direction_sign: -1})
      assert D.eq?(VehicleMotion.speed_km_h(state), D.new("-1.24"))
    end

    test "a signed rotation keeps its own sign, whatever the command says" do
      # A motor controller reports a negative rpm in reverse; applying
      # the command's sign on top would read two negatives as forward.
      state =
        state(%{
          rotation_signed: true,
          rotation_per_minute: D.new("-163.2"),
          direction_sign: -1
        })

      assert D.eq?(VehicleMotion.speed_km_h(state), D.new("-1.24"))
    end
  end

  describe "unknown is not zero" do
    test "a nil rotation is a nil speed, encoded as zero with speed_valid false" do
      state = state()
      assert VehicleMotion.speed_km_h(state) == nil
      assert VehicleMotion.wheel_rotation_per_minute(state) == nil
      assert D.eq?(VehicleMotion.speed_m_s(nil), D.new(0))
    end

    test "the sequence advances on a fresh sample and holds on nil" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :rotation_per_minute, value: D.new("163.2"), source: @sensor},
          state()
        )

      assert state.sequence == 1
      assert D.eq?(state.rotation_per_minute, D.new("163.2"))

      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :rotation_per_minute, value: nil, source: @sensor},
          state
        )

      assert state.sequence == 1
      assert state.rotation_per_minute == nil
    end

    test "the sequence wraps at 255" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :rotation_per_minute, value: D.new(0), source: @sensor},
          state(%{sequence: 255})
        )

      assert state.sequence == 0
    end

    test "only the configured rotation source is read" do
      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :rotation_per_minute, value: D.new("163.2"), source: Impostor},
          state()
        )

      assert unchanged.rotation_per_minute == nil
    end
  end

  describe "the frame definition" do
    test "is valid for emitting: every bit defined, signals in order and contiguous" do
      path = Path.join(:code.priv_dir(:ovcs_can), "can/components/ovcs/0x60B_vehicle_motion.yml")
      {:ok, yaml} = YamlElixir.read_from_file(path, atoms: true)
      frame = yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms)

      assert {:ok, _} = Cantastic.FrameSpecification.from_yaml(:ovcs, frame, :emit)
    end
  end

  describe "the distance" do
    test "the source's revolutions through the gearing and the wheel, in millimetres" do
      # 2.72 turns of the shaft roll one 0.0548 m wheel turn: 344.3 mm.
      state = state(%{revolutions: D.new("2.72")})
      assert D.eq?(VehicleMotion.distance_counter(state), D.new("0.344"))
    end

    test "wraps every 65.536 m, and stays positive in reverse" do
      wheel_turn = 2 * :math.pi() * @wheel_radius
      turns = D.from_float(-0.002 / wheel_turn * @ratio)
      assert D.eq?(VehicleMotion.distance_counter(state(%{revolutions: turns})), D.new("65.534"))
    end

    test "no revolutions yet is a zero counter, flagged invalid by the frame" do
      assert D.eq?(VehicleMotion.distance_counter(state()), D.new(0))
    end

    test "only the configured revolution source is read" do
      message = %Message{name: :revolutions, value: D.new(5), source: Elsewhere}
      {:noreply, state} = VehicleMotion.handle_info(message, state())
      assert state.revolutions == nil

      {:noreply, state} = VehicleMotion.handle_info(%{message | source: @sensor}, state)
      assert D.eq?(state.revolutions, D.new(5))
    end
  end

  describe "the steering angle" do
    test "scales the normalised request by the steering limit" do
      assert D.eq?(
               VehicleMotion.steering_angle(D.new("0.5"), D.from_float(0.52)),
               D.new("0.260")
             )
    end

    test "a negative steering_sign flips the reported angle back to REP-103" do
      factor = D.mult(D.from_float(0.52), -1)
      assert D.eq?(VehicleMotion.steering_angle(D.new("0.5"), factor), D.new("-0.260"))
    end

    test "only the selected commander moves the request" do
      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_steering, value: D.new("1"), source: Impostor},
          state()
        )

      assert D.eq?(unchanged.requested_steering, D.new(0))
    end
  end

  describe "following the manager" do
    test "adopts the sources the manager names, from the manager only" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :requested_throttle_source, value: NewCommander, source: @manager},
          state()
        )

      assert state.requested_throttle_source == NewCommander

      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_steering_source, value: Impostor, source: NotTheManager},
          state()
        )

      assert unchanged.requested_steering_source == @commander
    end
  end
end
