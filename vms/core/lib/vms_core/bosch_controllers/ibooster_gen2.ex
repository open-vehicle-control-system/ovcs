defmodule VmsCore.Bosch.IboosterGen2 do
  use GenServer
  alias Cantastic.{Emitter, Receiver, Frame, Signal}
  alias Decimal, as: D
  alias VmsCore.Bus

  #@min_flow_rate 27136 # 0x6A00
  @zero_point_flow_rate 32256 # 0x7e00
  #@max_flow_rate 37376 # 0x9200
  @flow_rate_range  5120

  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{contact_source: contact_source}) do
    :ok = init_emitters()
    :ok = Receiver.subscribe(self(), :misc, ["ibooster_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      status: "off",
      driver_brake_apply: "not_init_or_off",
      internal_state: "no_mode_active",
      rod_position: @zero,
      loop_timer: timer,
      enabled: false,
      contact_source: contact_source,
      contact: false
    }}
  end

  defp init_emitters() do
    :ok = Emitter.configure(:misc, "vehicle_status", %{
      parameters_builder_function: &vehicle_status_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0,
        "external_request" => false
      }
    })
    :ok = Emitter.configure(:misc, "vehicle_alive", %{
      parameters_builder_function: &vehicle_alive_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0
      }
    })
    :ok = Emitter.configure(:misc, "brake_request", %{
      parameters_builder_function: &brake_request_frame_parameters_builder/1,
      initial_data: %{
        "counter" => 0,
        "flow_rate" => @zero_point_flow_rate,
        "external_request" => false
      }
    })
    :ok
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_ibooster()
      |> emit_metrics()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: "ibooster_status", signals: signals}}, state) do
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

  defp toggle_ibooster(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        :ok = Emitter.enable(:leaf_drive, ["vehicle_status", "vehicle_alive", "brake_request"])
        %{state | enabled: true}
      {true, :off} ->
        :ok = Emitter.disable(:leaf_drive, ["vehicle_status", "vehicle_alive", "brake_request"])
        :ok = VmsCore.Controllers.GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end

  def activate_external_request() do
    set_external_request("brake_request", true)
    set_external_request("vehicle_status", true)
    set_flow_rate(0)
  end

  def deactivate_external_request() do
    set_external_request("brake_request", false)
    set_external_request("vehicle_status", false)
    set_flow_rate(0)
  end

  def set_flow_rate(flow_rate_coeficient) do
    value = flow_rate_coeficient |> D.mult(@flow_rate_range) |> D.add(@zero_point_flow_rate)
    :ok = Emitter.update(:misc, "brake_request", fn (data) ->
      %{data | "flow_rate" => value}
    end)
  end

  defp set_external_request(frame_name, value) do
    :ok = Emitter.update(:misc, frame_name, fn (data) ->
      %{data | "external_request" => value}
    end)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :status, value: state.status, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :driver_brake_apply, value: state.driver_brake_apply, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :internal_state, value: state.internal_state, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :rod_position, value: state.rod_position, source: __MODULE__})
    state
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
