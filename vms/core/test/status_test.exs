defmodule VmsCore.StatusTest do
  @moduledoc """
  Boot reset scheduling and heartbeat state across consecutive loop ticks.
  The real Cantastic emitter holds the heartbeat; transmission stays disabled.
  """
  use ExUnit.Case, async: false

  alias Cantastic.{Emitter, FrameSpecification, Interface}
  alias VmsCore.Status

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        vms_status: "OK",
        emitted_vms_status: "OK",
        ready_to_drive: false,
        emitted_ready_to_drive: false,
        ready_to_drive_source: Vms,
        vms_status_source: Vms,
        loop_timer: nil,
        resetting: false,
        reset_generic_controllers_frame_enabled: false
      },
      overrides
    )
  end

  test "the boot reset enters reset mode and schedules its own end" do
    {:noreply, state} = Status.handle_info(:start_reset_mode, state())
    assert state.resetting

    # The end is a message to self, so the process never blocks.
    assert_receive :stop_reset_mode, 1_500

    {:noreply, state} = Status.handle_info(:stop_reset_mode, state)
    refute state.resetting
  end

  test "reset status persists across consecutive loops and restores the latest vehicle status" do
    path = Path.join(:code.priv_dir(:ovcs_can), "can/components/ovcs/0x1A0_vms_status.yml")
    {:ok, definition} = YamlElixir.read_from_file(path, atoms: true)
    definition = definition |> Jason.encode!() |> Jason.decode!(keys: :atoms)
    {:ok, specification} = FrameSpecification.from_yaml(:ovcs, definition, :emit)
    emitter = Interface.emitter_process_name(:ovcs, "vms_status")

    start_supervised!(
      {Emitter,
       %{
         process_name: emitter,
         frame_specification: specification,
         socket: nil,
         network_name: :ovcs
       }}
    )

    :ok =
      Emitter.configure(:ovcs, "vms_status", %{
        parameters_builder_function: :default,
        initial_data: %{"status" => "OK"}
      })

    resetting = state(%{resetting: true, reset_generic_controllers_frame_enabled: true})

    resetting =
      Enum.reduce(1..4, resetting, fn _tick, previous ->
        {:noreply, current} = Status.handle_info(:loop, previous)
        assert Emitter.get(emitter, & &1["status"]) == "RESETTING"
        current
      end)

    {:noreply, resetting} =
      Status.handle_info(
        %OvcsBus.Message{name: :vms_status, value: "FAILURE", source: Vms},
        resetting
      )

    {:noreply, resetting} = Status.handle_info(:loop, resetting)
    assert Emitter.get(emitter, & &1["status"]) == "RESETTING"

    {:noreply, stopped} = Status.handle_info(:stop_reset_mode, resetting)

    {:noreply, _state} =
      Status.handle_info(:loop, %{stopped | reset_generic_controllers_frame_enabled: false})

    assert Emitter.get(emitter, & &1["status"]) == "FAILURE"
  end
end
