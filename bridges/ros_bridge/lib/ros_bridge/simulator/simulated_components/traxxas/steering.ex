defmodule RosBridge.Simulator.SimulatedComponents.Traxxas.Steering do
  @moduledoc """
  An RC steering servo on a generic controller's external PWM, the
  inverse of `VmsCore.Components.Traxxas.Steering`.

  The request is recovered from the duty cycle the way that component
  builds it, 15 % ± 5 % of the period, and turned into a steering angle:
  `:steering_sign · (request − :neutral) · :steering_limit_rad`, REP-103.
  A disabled PWM leaves the wheels where they were. The servo is
  instant.

  ## Options

    * `:controller` (`"main_controller"`), `:pwm` (`0`), `:network`
      (`:ovcs`) — whose request frame to read.
    * `:steering_limit_rad` (required).
    * `:steering_sign` (required) — `1` if a positive request turns
      left, `-1` if it turns right: the sign the vehicle's
      `RosVelocityCommand` uses.
    * `:neutral` (`0.0`) — the request that drives straight: the trim
      the VMS adds to centre a servo whose neutral pulse does not.
  """
  @behaviour RosBridge.Simulator.SimulatedComponent

  alias Cantastic.Signal

  @center 0.15
  @half_travel 0.05
  @duty_cycle_range 65_535

  @impl RosBridge.Simulator.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)
    controller = Map.get(opts, :controller, "main_controller")
    network = Map.get(opts, :network, :ovcs)

    state = %{
      steering_limit_rad: Map.fetch!(opts, :steering_limit_rad),
      steering_sign: Map.fetch!(opts, :steering_sign),
      neutral: Map.get(opts, :neutral, 0.0),
      angle: 0.0
    }

    {state, [{network, "#{controller}_external_pwm#{Map.get(opts, :pwm, 0)}_request"}], []}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def handle_frame(
        _name,
        %{"enabled" => %Signal{value: true}, "duty_cycle" => duty},
        state,
        _now
      ),
      do: %{state | angle: angle(duty.value / @duty_cycle_range, state)}

  def handle_frame(_name, _signals, state, _now_ms), do: state

  @impl RosBridge.Simulator.SimulatedComponent
  def actuations(state, _vehicle, _now_ms), do: [{:steering, state.angle}]

  @doc "The REP-103 steering angle for a duty cycle fraction of the period."
  def angle(duty_fraction, state) do
    request = ((duty_fraction - @center) / @half_travel) |> max(-1.0) |> min(1.0)
    state.steering_sign * (request - state.neutral) * state.steering_limit_rad
  end
end
