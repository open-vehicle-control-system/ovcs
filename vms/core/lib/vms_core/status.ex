defmodule VmsCore.Status do
  @moduledoc """
    VMS status
  """
  use GenServer
  alias Cantastic.Emitter
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    ready_to_drive_source: ready_to_drive_source,
    vms_status_source: vms_status_source})
  do
    :ok = Emitter.configure(:ovcs, "vms_status", %{
      parameters_builder_function: &vms_status_frame_parameter_builder/1,
      initial_data: %{
        "status" => "ok",
        "counter" => 0,
        "ready_to_drive" => false
      },
      enable: true
    })
    :ok = Emitter.configure(:ovcs, "vms_command", %{
      parameters_builder_function: :default,
      initial_data: %{
        "command" => "reset_generic_controllers",
      }
    })
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      vms_status: "ok",
      emitted_vms_status: "ok",
      ready_to_drive: false,
      emitted_ready_to_drive: false,
      ready_to_drive_source: ready_to_drive_source,
      vms_status_source: vms_status_source,
      loop_timer: timer,
      resetting: false,
      reset_generic_controllers_frame_enabled: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> update_vms_status()
      |> update_ready_to_drive()
      |> emit_vms_command_if_required()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: source}, state) when source == state.ready_to_drive_source do
    {:noreply, %{state | ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :vms_status, value: vms_status, source: source}, state) when source == state.vms_status_source do
    {:noreply, %{state | vms_status: vms_status}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp update_vms_status(state) do
    cond do
      state.resetting && state.emitted_vms_status != "resetting" ->
        :ok = Emitter.update(:ovcs, "vms_status", fn (data) ->
          %{data | "status" => "resetting"}
        end)
        %{state | emitted_vms_status: "resetting"}
      state.emitted_vms_status != state.vms_status ->
        :ok = Emitter.update(:ovcs, "vms_status", fn (data) ->
          %{data | "status" => state.vms_status}
        end)
        %{state | emitted_vms_status: state.vms_status}
      true -> state
    end
  end

  defp update_ready_to_drive(state) do
    case state.emitted_ready_to_drive == state.ready_to_drive do
      true -> state
      false ->
        :ok = Emitter.update(:ovcs, "vms_status", fn (data) ->
          %{data | "ready_to_drive" => state.ready_to_drive}
        end)
        %{state | emitted_ready_to_drive: state.ready_to_drive}
    end
  end

  defp emit_vms_command_if_required(state) do
    cond do
      state.resetting && !state.reset_generic_controllers_frame_enabled ->
        :ok = Emitter.update(:ovcs, "vms_command", fn (data) ->
          %{data | "command" => "reset_generic_controllers"}
        end)
        Emitter.enable(:ovcs, "vms_command")
        %{state | reset_generic_controllers_frame_enabled: true}
      !state.resetting && state.reset_generic_controllers_frame_enabled ->
        Emitter.disable(:ovcs, "vms_command")
        %{state | reset_generic_controllers_frame_enabled: false}
      true -> state
    end
  end

  defp vms_status_frame_parameter_builder(data) do
    counter    = data["counter"]
    parameters = data
    data       = %{data | "counter" => counter(counter + 1)}
    {:ok, parameters, data}
  end

  @impl true
  def handle_call(:start_reset_mode, _from, state) do
    {:reply, :ok, %{state | resetting: true}}
  end

  def handle_call(:stop_reset_mode, _from, state) do
    {:reply, :ok, %{state | resetting: false}}
  end

  def reset_status() do
    GenServer.call(__MODULE__, :start_reset_mode);
    :timer.sleep(500)
    GenServer.call(__MODULE__, :stop_reset_mode)
  end

  defp counter(value) do
    rem(value, 4)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :resetting, value: state.resetting, source: __MODULE__})
    state
  end
end
