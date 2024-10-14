defmodule VmsCore.Components.Bosch.IBoosterGen2 do
  @moduledoc """
   Tesla Model3 IBooster Gen2
  """
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias Decimal, as: D
  alias VmsCore.{Bus, Components.OVCS.GenericController, PID}

  @zero D.new(0)

  @min_flow_rate 27_136 # 0x6A00
  @zero_point_flow_rate 32_256 # 0x7e00
  @max_flow_rate 37_376 # 0x9200
  @flow_rate_range  5120

  @min_rod_position @zero # TODO check in practice
  @max_rod_position D.new(40) # TODO check in practice
  @rod_position_range @max_rod_position |> D.sub(@min_rod_position)


  @pid_kp D.new(2)
  @pid_ki D.new("0.2")
  @pid_kd D.new("0.03")

  @zero D.new(0)
  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    contact_source: contact_source,
    controller: controller,
    power_relay_pin: power_relay_pin})
  do
    :ok = Receiver.subscribe(self(), :misc, ["ibooster_status"])
    Bus.subscribe("messages")
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
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      status: "off",
      driver_brake_apply: "not_init_or_off",
      internal_state: "no_mode_active",
      rod_position: @zero,
      loop_timer: timer,
      enabled: false,
      contact_source: contact_source,
      contact: :off,
      ready_to_drive: false,
      controller: controller,
      power_relay_pin: power_relay_pin,
      pid: nil,
      rod_position_target: @zero,
      automatic_mode_enabled: false,
      enable_automatic_mode: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_ibooster()
      |> check_ready_to_drive()
      |> toggle_automatic_mode()
      |> actuate()
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

  def handle_info(%VmsCore.Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp toggle_ibooster(state) do
    case {state.enabled, state.contact} do
      {false, :on} ->
        deactivate_external_request()
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, true)
        :ok = Emitter.enable(:misc, ["vehicle_status", "vehicle_alive", "brake_request"])
        %{state | enabled: true}
      {true, :off} ->
        deactivate_external_request()
        :ok = Emitter.disable(:misc, ["vehicle_status", "vehicle_alive", "brake_request"])
        :ok = GenericController.set_digital_value(state.controller, state.power_relay_pin, false)
        %{state | enabled: false}
      _ -> state
    end
  end

  defp check_ready_to_drive(state) do
    {:ok, power_relay_enabled} = GenericController.get_digital_value(state.controller, state.power_relay_pin)
    ready_to_drive = power_relay_enabled && state.enabled && state.status in ["ready", "actuation", "active_good_check"]
    %{state | ready_to_drive: ready_to_drive}
  end

  defp toggle_automatic_mode(state) do
    cond do
      state.automatic_mode_enabled && state.driver_brake_apply ->
        deactivate_external_request()
        %{state | enable_automatic_mode: false, automatic_mode_enabled: false}
      state.enable_automatic_mode && !state.automatic_mode_enabled ->
        pid = init_pid()
        activate_external_request()
        %{state | pid: pid, automatic_mode_enabled: true}
      !state.enable_automatic_mode && state.automatic_mode_enabled ->
        deactivate_external_request()
        %{state | automatic_mode_enabled: false}
      true ->
        state
    end
  end

  defp actuate(state) when state.automatic_mode_enabled do
    pid = PID.iterate(state.pid, state.rod_position_target, state.rod_position)
    set_flow_rate(pid.output)
    %{state | pid: pid}
  end
  defp actuate(state), do: state

  defp init_pid do
    PID.new(
      kp: @pid_kp,
      ki: @pid_ki,
      kd: @pid_kd,
      minimum_output: @min_flow_rate,
      maximum_output: @max_flow_rate,
      reset_derivative_when_setpoint_changes: true
    )
  end

  defp activate_external_request do
    set_external_request("brake_request", true)
    set_external_request("vehicle_status", true)
    set_flow_rate(@zero_point_flow_rate)
  end

  defp deactivate_external_request do
    set_external_request("brake_request", false)
    set_external_request("vehicle_status", false)
    set_flow_rate(@zero_point_flow_rate)
  end

  defp set_flow_rate(flow_rate) do
    :ok = Emitter.update(:misc, "brake_request", fn (data) ->
      %{data | "flow_rate" => flow_rate}
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
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
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

  @impl true
  def handle_call({:brake_request, braking_request},  _from, state) do
    {:reply, :ok, %{state |
      enable_automatic_mode: true,
      rod_position_target: braking_request |> D.mult(@rod_position_range)
    }}
  end

  @impl true
  def handle_call(:deactivate_brake_request,  _from, state) do
    {:reply, :ok, %{state |
      enable_automatic_mode: false,
      rod_position_target: @min_rod_position
    }}
  end

  def brake_request(braking_request) do
    GenServer.call(__MODULE__, {:brake_request, braking_request})
  end

  def deactivate_brake_request do
    GenServer.call(__MODULE__, :deactivate_brake_request)
  end
end
