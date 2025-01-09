defmodule VmsCore.Components.OVCS.Ros2Control.Throttle do
  @moduledoc """
    Control throttle based on ros2 control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias VmsCore.{Bus, PID}

  @loop_period 10
  @zero D.new(0)
  @min_value 0 # in km/h
  @max_value 15 # in km/h
  @kp D.new("0.2")
  @ki D.new("0.1")
  @kd D.new("0.1")

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    channel_frame_name = "ros2_control"
    speed_frame_name = "abs_status"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    :ok = Receiver.subscribe(self(), :polo_drive, speed_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    state = %{
      loop_timer: timer,
      frame_name: channel_frame_name,
      speed_frame_name: speed_frame_name,
      name: "linear",
      speed_name: "speed",
      desired_speed: @zero,
      actual_speed: @zero,
      requested_throttle: @zero,
      requested_gear: :parking,
      pid: nil,
      kp: @kp,
      ki: @ki,
      kd: @kd
    }
    pid = init_pid(state)
    {:ok, %{state | pid: pid}}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_throttle()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.frame_name do
    requested_speed = signals[state.name].value
    desired_speed = requested_speed |> D.min(@max_value) |> D.max(@min_value)
    {:noreply, %{state | desired_speed: desired_speed}}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.speed_frame_name do
    actual_speed = signals[state.speed_name].value
    {:noreply, %{state | actual_speed: actual_speed}}
  end

  defp compute_throttle(state) do
    pid = PID.iterate(state.pid, state.actual_speed, state.desired_speed)
    requested_throttle = pid.output
    requested_gear = if requested_throttle >= 0, do: :drive, else: :reverse
    %{state | requested_throttle: requested_throttle, requested_gear: requested_gear, pid: pid}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_gear, value: state.requested_gear, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :requested_throttle, value: state.requested_throttle, source: __MODULE__})
    state
  end

  defp init_pid(state) do
    PID.new(
      kp: state.kp,
      ki: state.ki,
      kd: state.kd,
      reset_derivative_when_setpoint_changes: true
    )
  end
end
