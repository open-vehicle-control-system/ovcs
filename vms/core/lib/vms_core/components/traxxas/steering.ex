defmodule VmsCore.Components.Traxxas.Steering do
  @moduledoc """
    Traxxas' steering controlled by a PWM signal
  """
  use GenServer
  alias VmsCore.Components.OVCS.GenericController

  @loop_period 10
  @pwm_duty_cycle_range 65_536
  @pwm_frequency 100

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
      external_pwm_id: external_pwm_id
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    # state = state
    #   |> toggle_motor()
    #   |> set_direction()
    #   |> set_duty_cycle()
    {:noreply, state}
  end
end
