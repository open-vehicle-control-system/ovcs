defmodule VmsCore.Components.OVCS.SteeringColumnTest do
  @moduledoc """
  The steering column steers whenever `Managers.ControlLevel` names a
  steering source, whatever the level: the vehicle's source map decides
  which levels steer.

  Driven through `handle_info/2` against a stub state, with a stand-in
  generic controller that records each request: `init/1` would need
  the CAN stack.
  """
  use ExUnit.Case, async: true
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.SteeringColumn

  @manager ControlLevelManager
  @power_relay_pin 6

  defmodule RecordingController do
    @moduledoc false
    use GenServer

    def init(test), do: {:ok, test}

    def handle_call(request, _from, test) do
      send(test, {:controller, request})
      {:reply, :ok, test}
    end
  end

  setup do
    {:ok, controller} = GenServer.start_link(RecordingController, self())
    %{column: column(controller)}
  end

  defp column(controller) do
    %{
      angle: D.new(0),
      angular_speed: D.new(0),
      trimming_valid: true,
      calibration_valid: true,
      sensor_ready: true,
      power_relay_controller: controller,
      actuation_controller: controller,
      power_relay_pin: @power_relay_pin,
      direction_pin: 1,
      external_pwm_id: 0,
      requested_steering_source: nil,
      requested_steering: D.new(0),
      emitted_frequency: nil,
      emitted_direction: nil,
      pid: nil,
      input_filter: nil,
      automatic_mode_enabled: false,
      desired_angle: D.new(0),
      target_motor_speed_percentage: D.new(0),
      selected_control_level_source: @manager,
      max_steering_angle_deg: D.new(400),
      kp: D.new("0.5"),
      ki: D.new(0),
      kd: D.new(0),
      input_deadband: D.new("0.01"),
      input_alpha: D.new("0.5")
    }
  end

  defp deliver(state, name, value, source) do
    {:noreply, state} =
      SteeringColumn.handle_info(%Message{name: name, value: value, source: source}, state)

    state
  end

  defp loop(state) do
    {:noreply, state} = SteeringColumn.handle_info(:loop, state)
    state
  end

  for level <- [:radio, :ros] do
    test "powers the stepper driver under #{inspect(level)} once a steering source is named",
         %{column: column} do
      steering =
        column
        |> deliver(:selected_control_level, unquote(level), @manager)
        |> deliver(:requested_steering_source, SomeSteering, @manager)
        |> loop()

      assert steering.automatic_mode_enabled
      assert_received {:controller, {:set_digital_value, @power_relay_pin, true}}
    end
  end

  test "stays unpowered while no steering source is named", %{column: column} do
    idle = column |> deliver(:requested_steering_source, nil, @manager) |> loop()

    refute idle.automatic_mode_enabled
    refute_received {:controller, {:set_digital_value, @power_relay_pin, true}}
  end

  test "cuts the stepper driver when the manager stops naming a source", %{column: column} do
    released =
      column
      |> deliver(:requested_steering_source, SomeSteering, @manager)
      |> loop()
      |> deliver(:requested_steering_source, nil, @manager)
      |> loop()

    refute released.automatic_mode_enabled
    assert_received {:controller, {:set_digital_value, @power_relay_pin, false}}
  end
end
