defmodule VmsCore.Components.OVCS.Ros2Control.Steering do
  @moduledoc """
    Control steering based on ros2 control's input
  """
  use GenServer
  alias Cantastic.{Receiver, Frame}
  alias Decimal, as: D
  alias VmsCore.Bus

  @loop_period 10
  @zero 0
  @min_angle -:math.pi()/4 # in rad to be fetched from composer ? THIS IS WHEELS ORIENTATION NOT STEERING WHEEL ANGLE
  @max_angle :math.pi()/4 # in rad to be fetched from composer ? THIS IS WHEELS ORIENTATION NOT STEERING WHEEL ANGLE
  @range :math.pi()/2 # To be computed from min and max angles

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    channel_frame_name = "ros2_control"
    :ok = Receiver.subscribe(self(), :ovcs, channel_frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      frame_name: channel_frame_name,
      angular_name: "angular",
      linear_name: "linear",
      desired_angle: @zero,
      requested_steering: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> compute_steering()
      |> emit()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state) when name == state.frame_name do
    linear = signals[state.linear_name].value
    angular = signals[state.angular_name].value
    requested_angle = compute_steering_angle_from_rotation_velocity(linear, angular)
    desired_angle = requested_angle |> D.min(@max_angle) |> D.max(@min_angle)
    {:noreply, %{state | desired_angle: desired_angle}}
  end

  defp compute_steering(state) do
    desired_angle = state.desired_angle
    requested_steering = (desired_angle-@max_angle)/@range
    %{state | requested_steering: requested_steering}
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{name: :requested_steering, value: state.requested_steering, source: __MODULE__})
    state
  end

  defp compute_steering_angle_from_rotation_velocity(_linear, angular) when angular == 0 do
    0
  end

  defp compute_steering_angle_from_rotation_velocity(linear, angular) when angular != 0 do
    radius = linear/angular
    wheelbase = 1.0 # To be fetched from vehicle config, in meters
    :math.atan(wheelbase/radius)
  end
end
