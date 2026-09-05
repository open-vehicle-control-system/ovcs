defmodule VmsCore.Components.Traxxas.Throttle do
  @moduledoc """
    Traxxas' ESC throttle controlled by a PWM signal

  ## The feel curve

  A joystick or trigger request is squared (keeping its sign) before it
  becomes a duty cycle, so small deflections give fine control and full
  deflection still gives full power. That is a property of a *hand* on
  an axis, not of the actuator: a commander that sends a physical
  quantity -- `Ros2Control.Velocity` normalises metres per second --
  expects the request applied as is, or a planner asking for a fifth of
  full speed gets a twenty-fifth.

  `:linear_sources` lists the sources whose request is already a
  physical quantity. Every other source goes through the curve.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period 10
  @pwm_frequency 100
  @neutral_duty_cycle_percentage D.new("0.15")
  @duty_cycle_percentage_range D.new("0.05")
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          controller: controller,
          external_pwm_id: external_pwm_id,
          selected_control_level_source: selected_control_level_source
        } = args
      ) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       external_pwm_id: external_pwm_id,
       selected_control_level_source: selected_control_level_source,
       linear_sources: Map.get(args, :linear_sources, []),
       # Starts nil: nothing commands this actuator until the manager
       # names a source. The manager's default level does that on its
       # first tick.
       requested_throttle_source: nil,
       requested_throttle: @zero,
       throttle: @zero
     }}
  end

  @impl true
  def handle_info(
        %Bus.Message{
          name: :requested_throttle_source,
          value: requested_throttle_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing. Without this
    # the last request would persist — `handle_info` for
    # `:requested_throttle` gates on the source, so with no source no
    # message matches and the actuator holds. On the throttle that
    # means a vehicle that keeps driving after being switched to a
    # safe level, which is the same hazard as a stale CAN frame.
    requested = if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle

    {:noreply,
     %{
       state
       | requested_throttle_source: requested_throttle_source,
         requested_throttle: requested
     }}
  end

  def handle_info(:loop, state) do
    state =
      state
      |> apply_throttle()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp apply_throttle(state) do
    case D.eq?(state.throttle, state.requested_throttle) do
      true ->
        state

      false ->
        duty_cycle_percentage =
          state.requested_throttle
          |> shape(state.requested_throttle_source in state.linear_sources)
          |> D.mult(@duty_cycle_percentage_range)
          |> D.add(@neutral_duty_cycle_percentage)

        :ok =
          GenericController.set_external_pwm(
            state.controller,
            state.external_pwm_id,
            true,
            duty_cycle_percentage,
            @pwm_frequency
          )

        %{state | throttle: state.requested_throttle}
    end
  end

  # Signed square: `requested * |requested|` keeps the sign and the
  # endpoints while flattening the middle of the travel.
  @doc false
  def shape(requested, true = _linear), do: requested
  def shape(requested, false), do: requested |> D.abs() |> D.mult(requested)

  # TODO remove
  @impl true
  def handle_call({:test_request_throttle, value}, _from, state) do
    {:reply, :ok, %{state | requested_throttle: value}}
  end

  # TODO remove
  def test_request_throttle(value) do
    GenServer.call(__MODULE__, {:test_request_throttle, value})
  end
end
