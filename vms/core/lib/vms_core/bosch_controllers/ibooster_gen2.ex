defmodule VmsCore.Bosch.IboosterGen2 do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D

  @network_name :ibooster_yaw
  @brake_status_frame_name "brake_status"
  @ibooster_status_frame_name "ibooster_status"
  @vehicle_status_frame_name "vehicle_status"
  @brake_request_frame_name "brake_request"
  @vehicle_alive_frame_name "vehicle_alive"

  @min_flow_rate 27136 # 0x6A00
  @zero_point_flow_rate 32256 # 0x7e00
  @max_flow_rate 37376 # 0x9200
  @flow_rate_range  5120

  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = init_emitters()
    :ok = Receiver.subscribe(self(), @network_name, [@ibooster_status_frame_name])
    :ok = Emitter.enable(@network_name, [@vehicle_status_frame_name, @vehicle_alive_frame_name, @brake_request_frame_name])
    {:ok, %{
      status: "off",
      driver_brake_apply: "not_init_or_off",
      internal_state: "no_mode_active",
      rod_position: @zero
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @ibooster_status_frame_name, signals: signals}}, state) do
    %{
      "status" => %Signal{value: status},
      "driver_brake_apply" => %Signal{value: driver_brake_apply},
      "internal_state" => %Signal{value: internal_state},
      "rod_position" => %Signal{value: rod_position}
    } = signals
    {:noreply, %{
      state |
        status: status,
        driver_brake_apply: driver_brake_apply,
        internal_state: internal_state,
        rod_position: rod_position
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

  def set_flow_rate(percent) do
    value = D.div(percent, 100) |> D.mult(@flow_rate_range) |> D.add(@zero_point_flow_rate)
    :ok = Emitter.update(@network_name, @brake_request_frame_name, fn (data) ->
      %{data | "flow_rate" => value}
    end)
  end

  def activate_external_request() do
    set_external_request(@brake_request_frame_name, true)
    set_external_request(@vehicle_status_frame_name, true)
    set_flow_rate(0)
  end

  def deactivate_external_request() do
    set_external_request(@brake_request_frame_name, false)
    set_external_request(@vehicle_status_frame_name, false)
    set_flow_rate(0)
  end

  defp set_external_request(frame_name, value) do
    :ok = Emitter.update(@network_name, frame_name, fn (data) ->
      %{data | "external_request" => value}
    end)
  end

  defp init_emitters() do
    :ok = Emitter.configure(@network_name, @vehicle_status_frame_name, %{
      parameters_builder_function: &vehicle_status_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0,
        "external_request" => false
      }
    })
    :ok = Emitter.configure(@network_name, @vehicle_alive_frame_name, %{
      parameters_builder_function: &vehicle_alive_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      }
    })
    :ok = Emitter.configure(@network_name, @brake_request_frame_name, %{
      parameters_builder_function: &brake_request_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0,
        "flow_rate" => @zero_point_flow_rate,
        "external_request" => false
      }
    })
    :ok
  end

  defp vehicle_status_frame_parameters_builder(data) do
    counter = data["counter"]
    parameters = %{
      "counter" => counter(counter),
      "external_request" =>  data["external_request"],
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
      "counter" => counter(counter),
      "flow_rate" => data["flow_rate"],
      "external_request" => data["external_request"],
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
