defmodule VmsCore.SteeringColumn do
  use GenServer

  @loop_period 10
  @min_duty_cycle 0 + 5
  @max_duty_cycle 4095 - 5
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
    pwm_pin: pwm_pin})
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
      pwm_pin: pwm_pin,
      emitted_duty_cycle: @min_duty_cycle,
      duty_cycle: @min_duty_cycle,
      emitted_direction: :clockwise,
      direction: :clockwise
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_motor()
      |> set_direction()
      |> set_duty_cycle()
    {:noreply, state}
  end

  defp toggle_motor(state) do
    case {state.enabled, state.enable} do
      {false, true} ->
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, true)
        %{state | enabled: true}
      {true, :off} ->
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, true)
        %{state | enabled: false}
      _ -> state
    end
  end

  defp set_direction(state) do
    case state.emitted_direction == state.direction  do
      true -> state
      false ->
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.actuation_controller, state.direction_pin,  @direction_mapping[state.direction])
        %{state | emitted_direction: state.direction}
    end
  end

  defp set_duty_cycle(state) do
    case state.emitted_duty_cycle == state.duty_cycle  do
      true -> state
      false ->
        :ok = VmsCore.Controllers.GenericController.set_pwm_duty_cycle(state.actuation_controller, state.pwm_pin,  state.duty_cycle)
        %{state | emitted_duty_cycle: state.duty_cycle}
    end
  end

  @impl true
  def handle_call({:activate, duty_cycle, direction}, _from, state) do
    {:reply, :ok, %{state | enable: true, duty_cycle: duty_cycle, direction: direction}}
  end
  def handle_call(:deactivate, _from, state) do
    {:reply, :ok, %{state | enable: false, duty_cycle: @min_duty_cycle}}
  end

  def activate(duty_cycle, direction) do
    duty_cycle = max(@min_duty_cycle, duty_cycle) |> min(@max_duty_cycle)
    GenServer.call(__MODULE__, {:activate, duty_cycle, direction})
  end

  def deactivate() do
    GenServer.call(__MODULE__, :deactivate)
  end
end
