defmodule VmsCore.Components.Traxxas.Steering do
  @moduledoc """
    Traxxas' steering controlled by a PWM signal
  """
  use GenServer
  alias Decimal, as: D
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
    external_pwm_id: external_pwm_id})
  do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      controller: controller,
      external_pwm_id: external_pwm_id,
      requested_steering: @zero,
      steering: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> steer()
    {:noreply, state}
  end

  defp steer(state) do
    case state.steering == state.requested_steering  do
      true -> state
      false ->
        duty_cycle_percentage = state.requested_steering |> D.mult(@duty_cycle_percentage_range) |> D.add(@center_duty_cycle_percentage)
        :ok = GenericController.set_external_pwm(state.controller, state.external_pwm_id, true, duty_cycle_percentage, @pwm_frequency)
        %{state | steering: state.requested_steering}
    end
  end

  #TODO remove
  @impl true
  def handle_call({:test_request_steering, value},  _from, state) do
    {:reply, :ok, %{state | requested_steering: value}}
  end

  def test_request_steering(value) do
    GenServer.call(__MODULE__, {:test_request_steering, value})
  end
end
