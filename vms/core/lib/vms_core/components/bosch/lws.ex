defmodule VmsCore.Components.Bosch.LWS do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D
  alias VmsCore.Bus

  @zero D.new(0)
  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Emitter.configure(:misc, "lws_config", %{
      parameters_builder_function: :default,
      initial_data: %{
        "command" => "reset_angle_calibration_status",
      }
    })
    :ok = Receiver.subscribe(self(), :misc, ["lws_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      angle: @zero,
      angular_speed: @zero,
      trimming_valid: false,
      calibration_valid: false,
      sensor_ready: false,
      loop_timer: timer
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit_metrics()
    {:noreply, state}
  end

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

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :angle, value: state.angle, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :angular_speed, value: state.angular_speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :trimming_valid, value: state.trimming_valid, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :calibration_valid, value: state.calibration_valid, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :sensor_ready, value: state.sensor_ready, source: __MODULE__})
    state
  end

  def calibrate_angle_0 do
    :ok = reset_angle_calibration_status()
    :timer.sleep(500)
    :ok = set_angle_0()
  end

  defp reset_angle_calibration_status do
    :ok = Emitter.update(:misc, "lws_config", fn (data) ->
      %{data | "command" => "reset_angle_calibration_status"}
    end)
    :ok = Emitter.enable(:misc, "lws_config")
    :timer.sleep(500)
    :ok = Emitter.disable(:misc, "lws_config")
  end

  defp set_angle_0 do
    :ok = Emitter.update(:misc, "lws_config", fn (data) ->
      %{data | "command" => "set_angle_zero"}
    end)
    :ok = Emitter.enable(:misc, "lws_config")
    :timer.sleep(500)
    :ok = Emitter.disable(:misc, "lws_config")
  end
end
