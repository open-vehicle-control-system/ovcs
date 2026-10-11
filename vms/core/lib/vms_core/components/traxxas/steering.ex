defmodule VmsCore.Components.Traxxas.Steering do
  @moduledoc """
  A Traxxas steering servo, driven by a generic controller's external PWM
  (`:controller`, `:external_pwm_id`) from the `:requested_steering` of
  the source the control level manager names.

  `:trim` (default `0`) is added to every steering request, in the
  same `[-1, 1]` units, before the result is clamped to `[-1, 1]`.
  It centres a servo whose neutral pulse does not drive the wheels
  straight.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period_ms 10
  # The standard RC servo frame; neutral and half-travel are fractions of its period.
  @pwm_frequency_hz 100
  @center_duty_cycle_percentage D.new("0.15")
  @duty_cycle_percentage_range D.new("0.05")
  @zero D.new(0)
  @one D.new(1)
  @minus_one D.new(-1)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(
        %{
          controller: controller,
          external_pwm_id: external_pwm_id,
          selected_control_level_source: selected_control_level_source
        } = args
      ) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       external_pwm_id: external_pwm_id,
       selected_control_level_source: selected_control_level_source,
       trim: D.new(Map.get(args, :trim, 0)),
       # Nothing commands this actuator until the manager names a
       # source.
       requested_steering_source: nil,
       requested_steering: @zero,
       # nil so the first tick sends the trimmed centre.
       steering: nil
     }}
  end

  @impl GenServer
  def handle_info(
        %Bus.Message{
          name: :requested_steering_source,
          value: requested_steering_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Hold on the way to a level that commands nothing, unlike the
    # throttle: snapping the wheels straight mid-corner is a new hazard,
    # not a mitigation.
    {:noreply, %{state | requested_steering_source: requested_steering_source}}
  end

  def handle_info(:loop, state) do
    state =
      state
      |> steer()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{name: :requested_steering, value: requested_steering, source: source},
        state
      )
      when source == state.requested_steering_source do
    {:noreply, %{state | requested_steering: requested_steering}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp steer(state) do
    case state.steering != nil and D.eq?(state.steering, state.requested_steering) do
      true ->
        state

      false ->
        duty_cycle_percentage =
          state.requested_steering
          |> D.add(state.trim)
          |> D.max(@minus_one)
          |> D.min(@one)
          |> D.mult(@duty_cycle_percentage_range)
          |> D.add(@center_duty_cycle_percentage)

        :ok =
          GenericController.set_external_pwm(
            state.controller,
            state.external_pwm_id,
            true,
            duty_cycle_percentage,
            @pwm_frequency_hz
          )

        %{state | steering: state.requested_steering}
    end
  end
end
