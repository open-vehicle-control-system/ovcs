defmodule VmsCore.Components.Traxxas.Steering do
  @moduledoc """
    Traxxas' steering controlled by a PWM signal
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period 10
  @pwm_frequency 100
  @center_duty_cycle_percentage D.new("0.15")
  @duty_cycle_percentage_range D.new("0.05")
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
        controller: controller,
        external_pwm_id: external_pwm_id,
        selected_control_level_source: selected_control_level_source
      }) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       controller: controller,
       external_pwm_id: external_pwm_id,
       selected_control_level_source: selected_control_level_source,
       # Starts nil: nothing commands this actuator until the manager
       # names a source. The manager's default level does that on its
       # first tick.
       requested_steering_source: nil,
       requested_steering: @zero,
       steering: @zero
     }}
  end

  @impl true
  def handle_info(
        %Bus.Message{
          name: :requested_steering_source,
          value: requested_steering_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing. Without this
    # the last request would persist — `handle_info` for
    # `:requested_steering` gates on the source, so with no source no
    # message matches and the actuator holds. On the throttle that
    # means a vehicle that keeps driving after being switched to a
    # safe level, which is the same hazard as a stale CAN frame.
    requested = if is_nil(requested_steering_source), do: @zero, else: state.requested_steering

    {:noreply,
     %{
       state
       | requested_steering_source: requested_steering_source,
         requested_steering: requested
     }}
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
    case D.eq?(state.steering, state.requested_steering) do
      true ->
        state

      false ->
        duty_cycle_percentage =
          state.requested_steering
          |> D.mult(@duty_cycle_percentage_range)
          |> D.add(@center_duty_cycle_percentage)

        :ok =
          GenericController.set_external_pwm(
            state.controller,
            state.external_pwm_id,
            true,
            duty_cycle_percentage,
            @pwm_frequency
          )

        %{state | steering: state.requested_steering}
    end
  end

  # TODO remove
  @impl true
  def handle_call({:test_request_steering, value}, _from, state) do
    {:reply, :ok, %{state | requested_steering: value}}
  end

  # TODO remove
  def test_request_steering(value) do
    GenServer.call(__MODULE__, {:test_request_steering, value})
  end
end
