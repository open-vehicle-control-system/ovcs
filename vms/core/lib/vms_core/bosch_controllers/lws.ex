defmodule VmsCore.Bosch.Lws do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @network_name :misc

  @lws_status_frame_name "lws_status"
  @lws_config_frame_name "lws_config"

  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @lws_config_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        "command" => "reset_angle_calibration_status",
      }
    })
    :ok = Receiver.subscribe(self(), @network_name, [@lws_status_frame_name])
    {:ok, %{
      angle: @zero,
      angular_speed: @zero,
      trimming_valid: false,
      calibration_valid: false,
      sensor_ready: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{
      "steering_wheel_angle" => %Signal{value: angle},
      "steering_wheel_angular_speed" => %Signal{value: angular_speed},
      "steering_wheel_trimming_valid" => %Signal{value: trimming_valid},
      "steering_wheel_calibration_valid" => %Signal{value: calibration_valid},
      "steering_wheel_sensor_ready" => %Signal{value: sensor_ready}
    } = signals
    {:noreply, %{
      state |
        angle: angle,
        angular_speed: angular_speed,
        trimming_valid: trimming_valid,
        calibration_valid: calibration_valid,
        sensor_ready: sensor_ready
      }
    }
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def state() do
    GenServer.call(__MODULE__, :state)
  end

  def reset_angle_calibration_status do
    :ok = Emitter.update(@network_name, @lws_config_frame_name, fn (data) ->
      IO.inspect data
      %{data | "command" => "reset_angle_calibration_status"}
    end)
    :ok = Emitter.enable(@network_name, @lws_config_frame_name)
    :timer.sleep(1000)
    :ok = Emitter.disable(@network_name, @lws_config_frame_name)
  end

  def set_angle_0 do
    :ok = Emitter.update(@network_name, @lws_config_frame_name, fn (data) ->
      %{data | "command" => "set_angle_zero"}
    end)
    :ok = Emitter.enable(@network_name, @lws_config_frame_name)
    :timer.sleep(1000)
    :ok = Emitter.disable(@network_name, @lws_config_frame_name)
  end
end
