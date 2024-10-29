defmodule VmsCore.Components.Traxxas.Throttle do
  @moduledoc """
    Traxxas' steering controlled by a PWM signal
  """
  use GenServer
  alias Decimal, as: D
  alias VmsCore.Bus
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
  def init(%{
    controller: controller,
    external_pwm_id: external_pwm_id,
    requested_throttle_source: requested_throttle_source})
  do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      external_pwm_id: external_pwm_id,
      requested_throttle_source: requested_throttle_source,
      requested_throttle: @zero,
      throttle: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> apply_throttle()
    {:noreply, state}
  end
  def handle_info(%Bus.Message{name: :requested_throttle, value: requested_throttle, source: source}, state) when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp apply_throttle(state) do
    case D.eq?(state.throttle, state.requested_throttle)  do
      true -> state
      false ->
        duty_cycle_percentage = state.requested_throttle |> D.mult(@duty_cycle_percentage_range) |> D.add(@neutral_duty_cycle_percentage)
        exponantial_throttle_percentage = duty_cycle_percentage |> D.mult(duty_cycle_percentage) |> D.mult(duty_cycle_percentage)
        :ok = GenericController.set_external_pwm(state.controller, state.external_pwm_id, true, exponantial_throttle_percentage, @pwm_frequency)
        %{state | throttle: state.requested_throttle}
    end
  end

  #TODO remove
  @impl true
  def handle_call({:test_request_throttle, value},  _from, state) do
    {:reply, :ok, %{state | requested_throttle: value}}
  end
  #TODO remove
  def test_request_throttle(value) do
    GenServer.call(__MODULE__, {:test_request_throttle, value})
  end
end
