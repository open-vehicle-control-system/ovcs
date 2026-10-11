defmodule VmsCore.Components.Bosch.IBoosterGen2 do
  @moduledoc """
  A Bosch iBooster Gen2 electromechanical brake booster (Tesla Model 3),
  on the `:misc` CAN network.

  The pedal acts on the booster mechanically at all times. While the
  contact is on, a generic controller's relay powers the booster and its
  keep-alive frames are emitted. Under the `:radio` control level a
  negative throttle request becomes a rod position target, which a PID
  loop reaches by commanding the booster's flow rate.

  Publishes the booster's status, rod position and target, flow rate,
  `:manual_breaking` (the driver is braking or the booster cannot) and
  `:ready_to_drive`.

  ## Options

    * `:selected_control_level_source` — the manager that names the
      control level and the throttle source.
    * `:contact_source` — the component publishing `:contact`.
    * `:controller`, `:power_relay_pin` — the generic controller digital
      pin switching the booster's power.
  """
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias OvcsControl.PID
  alias VmsCore.Components.OVCS.GenericController

  @zero D.new(0)

  # The booster accepts flow rates from 0x6A00 to 0x9200 around this zero point.
  @zero_point_flow_rate 0x7E00
  @flow_rate_range 0x1400

  @min_rod_position_mm @zero
  @max_rod_position_mm D.new("16.56")
  @rod_position_range_mm @max_rod_position_mm |> D.sub(@min_rod_position_mm)

  @kp D.new(250)
  @ki D.new(0)
  @kd D.new(0)

  @loop_period_ms 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{
        selected_control_level_source: selected_control_level_source,
        contact_source: contact_source,
        controller: controller,
        power_relay_pin: power_relay_pin
      }) do
    :ok = Receiver.subscribe(self(), :misc, ["ibooster_status"])
    Bus.subscribe("messages")

    :ok =
      Emitter.configure(:misc, "vehicle_status", %{
        parameters_builder_function: &vehicle_status_frame_parameters_builder/1,
        initial_data: %{
          "counter" => 0,
          "external_request" => false
        }
      })

    :ok =
      Emitter.configure(:misc, "vehicle_alive", %{
        parameters_builder_function: &vehicle_alive_frame_parameters_builder/1,
        initial_data: %{
          "counter" => 0
        }
      })

    :ok =
      Emitter.configure(:misc, "brake_request", %{
        parameters_builder_function: &brake_request_frame_parameters_builder/1,
        initial_data: %{
          "counter" => 0,
          "flow_rate" => @zero_point_flow_rate,
          "external_request" => false
        }
      })

    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       status: "off",
       driver_brake_apply: "not_init_or_off",
       internal_state: "no_mode_active",
       rod_position: @min_rod_position_mm,
       flow_rate: @zero,
       loop_timer: timer,
       enabled: false,
       selected_control_level_source: selected_control_level_source,
       selected_control_level: nil,
       requested_throttle_source: nil,
       requested_throttle: @zero,
       contact_source: contact_source,
       contact: :off,
       ready_to_drive: false,
       controller: controller,
       power_relay_pin: power_relay_pin,
       pid: nil,
       rod_position_target: @min_rod_position_mm,
       automatic_mode_enabled: false,
       requested_braking: @zero,
       manual_braking: false,
       kp: @kp,
       ki: @ki,
       kd: @kd
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_ibooster()
      |> check_ready_to_drive()
      |> toggle_automatic_mode()
      |> set_requested_braking()
      |> set_rod_position_target()
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

    {:noreply,
     %{
       state
       | status: status,
         driver_brake_apply: driver_brake_apply,
         manual_braking:
           driver_brake_apply in ["driver_applying_brake", "fault", "not_init_or_off"],
         internal_state: internal_state,
         rod_position: rod_position
     }}
  end

  def handle_info(
        %Bus.Message{
          name: :selected_control_level,
          value: selected_control_level,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    {:noreply, %{state | selected_control_level: selected_control_level}}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_throttle_source,
          value: requested_throttle_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing: with no source
    # no request message matches, and the last request would be held.
    requested_throttle =
      if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle

    {:noreply,
     %{
       state
       | requested_throttle_source: requested_throttle_source,
         requested_throttle: requested_throttle
     }}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state)
      when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  def handle_info(%Bus.Message{}, state) do
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

      _ ->
        state
    end
  end

  defp check_ready_to_drive(state) do
    {:ok, power_relay_enabled} =
      GenericController.get_digital_value(state.controller, state.power_relay_pin)

    ready_to_drive =
      power_relay_enabled && state.enabled &&
        state.status in ["ready", "actuation", "active_good_check"]

    %{state | ready_to_drive: ready_to_drive}
  end

  defp toggle_automatic_mode(state) do
    enable_automatic_mode = state.selected_control_level == :radio

    cond do
      enable_automatic_mode && !state.automatic_mode_enabled ->
        pid = init_pid(state)
        activate_external_request()
        %{state | pid: pid, automatic_mode_enabled: true}

      !enable_automatic_mode && state.automatic_mode_enabled ->
        deactivate_external_request()
        %{state | automatic_mode_enabled: false}

      true ->
        state
    end
  end

  defp set_requested_braking(state) when state.automatic_mode_enabled == true do
    requested_braking =
      case state.requested_throttle |> D.gt?(@zero) do
        true -> @zero
        false -> state.requested_throttle |> D.abs()
      end

    %{state | requested_braking: requested_braking}
  end

  defp set_requested_braking(state), do: state

  defp set_rod_position_target(state) when state.automatic_mode_enabled == true do
    rod_position_target = state.requested_braking |> D.mult(@rod_position_range_mm)
    %{state | rod_position_target: rod_position_target}
  end

  defp set_rod_position_target(state), do: state

  defp actuate(state) when state.automatic_mode_enabled do
    pid = PID.iterate(state.pid, state.rod_position, state.rod_position_target)
    flow_rate = @zero_point_flow_rate |> D.add(pid.output)
    set_flow_rate(flow_rate)
    %{state | pid: pid, flow_rate: flow_rate}
  end

  defp actuate(state), do: state

  defp init_pid(state) do
    PID.new(
      kp: state.kp,
      ki: state.ki,
      kd: state.kd,
      minimum_output: D.sub(@zero, @flow_rate_range),
      maximum_output: @flow_rate_range,
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
    :ok =
      Emitter.update(:misc, "brake_request", fn emitter_data ->
        %{emitter_data | "flow_rate" => flow_rate}
      end)
  end

  defp set_external_request(frame_name, enabled) do
    :ok =
      Emitter.update(:misc, frame_name, fn emitter_data ->
        %{emitter_data | "external_request" => enabled}
      end)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :status, value: state.status, source: __MODULE__})

    Bus.broadcast("messages", %Bus.Message{
      name: :driver_brake_apply,
      value: state.driver_brake_apply,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :manual_breaking,
      value: state.manual_braking,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :internal_state,
      value: state.internal_state,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :rod_position,
      value: state.rod_position,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :rod_position_target,
      value: state.rod_position_target,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :flow_rate,
      value: state.flow_rate,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :ready_to_drive,
      value: state.ready_to_drive,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :automatic_mode_enabled,
      value: state.automatic_mode_enabled,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_braking,
      value: state.requested_braking,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle_source,
      value: state.requested_throttle_source,
      source: __MODULE__
    })

    state
  end

  defp vehicle_status_frame_parameters_builder(emitter_data) do
    counter = emitter_data["counter"]

    parameters = %{
      "counter" => wrap_counter(counter),
      "external_request" => emitter_data["external_request"],
      "crc" => &crc8/1
    }

    emitter_data = %{emitter_data | "counter" => wrap_counter(counter + 1)}
    {:ok, parameters, emitter_data}
  end

  defp vehicle_alive_frame_parameters_builder(emitter_data) do
    counter = emitter_data["counter"]

    parameters = %{
      "counter" => wrap_counter(counter),
      "crc" => &crc8/1
    }

    emitter_data = %{emitter_data | "counter" => wrap_counter(counter + 1)}
    {:ok, parameters, emitter_data}
  end

  defp brake_request_frame_parameters_builder(emitter_data) do
    counter = emitter_data["counter"]

    parameters = %{
      "counter" => wrap_counter(counter),
      "flow_rate" => emitter_data["flow_rate"],
      "external_request" => emitter_data["external_request"],
      "crc" => &crc8/1
    }

    emitter_data = %{emitter_data | "counter" => wrap_counter(counter + 1)}
    {:ok, parameters, emitter_data}
  end

  defp crc8(payload) do
    CRC.calculate(
      payload,
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

  defp wrap_counter(counter), do: rem(counter, 16)

  @impl GenServer
  def handle_call({:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}}, _from, state) do
    {:reply, :ok, %{state | kp: kp, ki: ki, kd: kd}}
  end

  @doc "Replaces the PID gains used from the next switch into automatic mode."
  def set_pid_parameters(%{kp: kp, ki: ki, kd: kd}) do
    GenServer.call(__MODULE__, {:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}})
  end

  @doc "The rod position, in millimetres, of a released brake."
  def min_rod_position, do: @min_rod_position_mm

  @doc "The rod position, in millimetres, of a full automatic braking request."
  def max_rod_position, do: @max_rod_position_mm
end
