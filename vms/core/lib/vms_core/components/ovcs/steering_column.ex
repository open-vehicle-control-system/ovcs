defmodule VmsCore.Components.OVCS.SteeringColumn do
  @moduledoc """
    OVCS custom steering column using a stepper motor, generic controller and modified VW steering column
  """
  use GenServer
  alias VmsCore.Components.OVCS.GenericController
  alias Decimal, as: D

  @loop_period 10
  @min_frequency 100
  @frequency_range 300
  @duty_cycle_percentage D.new("0.5")
  @direction_mapping %{clockwise: true, counter_clockwise: false}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    power_relay_controller: power_relay_controller,
    power_relay_pin: power_relay_pin,
    actuation_controller: actuation_controller,
    direction_pin: direction_pin,
    external_pwm_id: external_pwm_id})
  do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      enable: false,
      enabled: false,
      power_relay_controller: power_relay_controller,
      actuation_controller: actuation_controller,
      power_relay_pin: power_relay_pin,
      direction_pin: direction_pin,
      external_pwm_id: external_pwm_id,
      emitted_frequency: @min_frequency,
      frequency: @min_frequency,
      emitted_direction: :clockwise,
      direction: :clockwise
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_motor()
      |> set_direction()
      |> set_speed()
    {:noreply, state}
  end

  defp toggle_motor(state) do
    case {state.enabled, state.enable} do
      {false, true} ->
        :ok = GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, true)
        %{state | enabled: true}
      {true, false} ->
        :ok = GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end

  defp set_direction(state) do
    case state.emitted_direction == state.direction  do
      true -> state
      false ->
        :ok = GenericController.set_digital_value(state.actuation_controller, state.direction_pin,  @direction_mapping[state.direction])
        %{state | emitted_direction: state.direction}
    end
  end

  defp set_speed(state) do
    frequency = state.frequency
    case state.emitted_frequency == frequency  do
      true -> state
      false ->
        enabled = frequency |> D.gt?(@min_frequency)
        :ok = GenericController.set_external_pwm(state.actuation_controller, state.external_pwm_id, enabled, @duty_cycle_percentage, frequency)
        %{state | emitted_frequency: frequency}
    end
  end

  @impl true
  def handle_call({:actuate, motor_speed_percentage}, _from, state) do
    direction = case motor_speed_percentage |> D.lt?(0) do
      true -> :counter_clockwise
      false -> :clockwise
    end
    frequency = motor_speed_percentage
      |> D.abs()
      |> D.mult(@frequency_range)
      |> D.add(@min_frequency)
    {:reply, :ok, %{state | enable: true, frequency: frequency, direction: direction}}
  end
  def handle_call(:deactivate, _from, state) do
    {:reply, :ok, %{state | enable: false, frequency: @min_frequency}}
  end

  def actuate(motor_speed_percentage) do
    GenServer.call(__MODULE__, {:actuate, motor_speed_percentage})
  end

  def deactivate do
    GenServer.call(__MODULE__, :deactivate)
  end
end
