defmodule VmsCore.Bosch.IboosterGen2 do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @yaw_network_name :ibooster_yaw
  @rod_status_frame_name "rod_status"
  @brake_status_frame_name "brake_status"
  @ibooster_status_frame_name "ibooster_status"

  @vehicle_network_name :ibooster_yaw
  @vehicle_status_frame_name "vehicle_status"
  @brake_request_frame_name "brake_request"
  @vehicle_alive_frame_name "vehicle_alive"

# vehicle_status_frame_name -> Party 1
# @brake_request_frame_name -> party 2
# @vehicle_alive_frame_name -> party 3

# max flow rate 0x9200 -> ml/s
# zero point flow rate 0x7e00
# min flow rate 0x6A00

  @impl true
  def init(_) do
    :ok = init_emitters()
    :ok = Receiver.subscribe(self(), @yaw_network_name, [@rod_status_frame_name, @brake_status_frame_name, @ibooster_status_frame_name])
    :ok = Emitter.enable(@vehicle_network_name, [@vehicle_status_frame_name, @vehicle_alive_frame_name, @brake_request_frame_name])
    {:ok, %{
      output_rod_target: 0,
      driver_brake_applied: false,
      brake_sensor_fault: false,
      ibooster_error: false,
      status: "off",
      driver_brake_apply: "not_init_or_off"
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @rod_status_frame_name, signals: signals}}, state) do
      %{"output_rod_target" => %Signal{value: output_rod_target}} = signals
      {:noreply, %{
        state |
        output_rod_target: output_rod_target,
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @brake_status_frame_name, signals: signals}}, state) do
    %{
      "driver_brake_applied" => %Signal{value: driver_brake_applied},
      "brake_sensor_fault" => %Signal{value: brake_sensor_fault},
      "ibooster_error" => %Signal{value: ibooster_error},
    } = signals
    {:noreply, %{
      state |
        driver_brake_applied: driver_brake_applied,
        brake_sensor_fault: brake_sensor_fault,
        ibooster_error: ibooster_error
      }
    }
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @ibooster_status_frame_name, signals: signals}}, state) do

    %{
      "status" => %Signal{value: status},
      "driver_brake_apply" => %Signal{value: driver_brake_apply}
    } = signals
    {:noreply, %{
      state |
        status: status,
        driver_brake_apply: driver_brake_apply,
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

  def set_flow_rate(value) do
    :ok = Emitter.update(@vehicle_network_name, @brake_request_frame_name, fn (data) ->
      %{data | "flow_rate" => value}
    end)
  end

  defp init_emitters() do
    :ok = Emitter.configure(@vehicle_network_name, @vehicle_status_frame_name, %{
      parameters_builder_function: &vehicle_status_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@vehicle_network_name, @vehicle_alive_frame_name, %{
      parameters_builder_function: &vehicle_alive_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@vehicle_network_name, @brake_request_frame_name, %{
      parameters_builder_function: &brake_request_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0,
        "flow_rate" => 32256,
      }
    })
    :ok
  end

  defp vehicle_status_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "counter" => counter(counter) + 64,
      "crc" => &crc8/1
    }

    data = %{data | "counter" => counter(counter + 1)}
    {:ok, parameters, data}
  end

  defp vehicle_alive_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "counter" => counter(counter),
      "crc" => &crc8/1
    }

    data = %{data | "counter" => counter(counter + 1)}
    {:ok, parameters, data}
  end

  defp brake_request_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "counter" => counter(counter) + 64,
      "flow_rate" =>  data["flow_rate"],
      "crc" => &crc8/1
    }

    data = %{data | "counter" => counter(counter + 1)}
    {:ok, parameters, data}
  end

  defp crc8(raw_data) do
    CRC.calculate(
      raw_data,
      %{
        width: 8,
        poly: 0x1D,
        init: 0xFF,
        refin: false,
        refout: false,
        xorout: 0xFF
      }
    )
  end

  defp counter(value) do
    rem(value, 16)
  end
end
