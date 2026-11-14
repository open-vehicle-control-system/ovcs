defmodule VmsCore.Components.Nissan.LeafAZE0.InverterTorqueTest do
  use ExUnit.Case, async: false
  alias Cantastic.{Emitter, FrameSpecification, Interface}
  alias Decimal, as: D
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter.Torque

  @network :inverter_torque_limit_test

  defmodule RelayFeedback do
    @moduledoc "A reported closed power relay; CAN emission uses the real Cantastic worker."
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    @impl GenServer
    def init(nil), do: {:ok, nil}
    @impl GenServer
    def handle_call({:get_digital_value, 7}, _from, state), do: {:reply, {:ok, true}, state}
  end

  defp decision(gear, request) do
    %{
      selected_gear: gear,
      requested_throttle: D.new(request),
      drive_max_torque_nm: D.new(120),
      reverse_max_torque_nm: D.new(40),
      effective_throttle_threshold: D.new("0.05")
    }
  end

  for {gear, maximum} <- [drive: 120, reverse: -40, neutral: 0, parking: 0] do
    test "#{gear} respects its torque limit across normalized and out-of-range requests" do
      for {request, fraction} <- [
            {"-32.768", "0"},
            {"-1", "0"},
            {"0", "0"},
            {"0.049", "0"},
            {"0.05", "0.05"},
            {"0.5", "0.5"},
            {"1", "1"},
            {"2", "1"},
            {"32.767", "1"}
          ] do
        assert D.equal?(
                 Torque.request(decision(unquote(gear), request)),
                 D.mult(D.new(fraction), unquote(maximum))
               )
      end
    end
  end

  test "the inverter writes bounded drive and reverse torque to the real emitter" do
    path =
      Path.join(
        :code.priv_dir(:ovcs_can),
        "can/components/nissan/leaf_aze0/0x1D4_vms_torque_request.yml"
      )

    {:ok, yaml} = YamlElixir.read_from_file(path, atoms: true)
    yaml = yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms)
    {:ok, specification} = FrameSpecification.from_yaml(@network, yaml, :emit)
    emitter = Interface.emitter_process_name(@network, "vms_torque_request")

    start_supervised!(
      {Emitter,
       %{
         process_name: emitter,
         frame_specification: specification,
         socket: nil,
         network_name: @network
       }}
    )

    :ok =
      Emitter.configure(@network, "vms_torque_request", %{
        parameters_builder_function: :default,
        initial_data: %{"requested_torque" => D.new(0)}
      })

    controller = start_supervised!({RelayFeedback, nil})

    for {gear, maximum} <- [drive: 120, reverse: -40], request <- ["2", "32.767"] do
      state =
        Map.merge(decision(gear, request), %{
          network: @network,
          controller: controller,
          power_relay_pin: 7,
          enabled: true,
          contact: :on,
          ready_to_drive: true,
          requested_throttle_source: TestCommander,
          requested_torque: D.new(0),
          rotation_per_minute: 0,
          effective_torque: 0,
          inverter_output_voltage: 0,
          inverter_communication_board_temperature: 0,
          insulated_gate_bipolar_transistor_temperature: 0,
          insulated_gate_bipolar_transistor_board_temperature: 0,
          motor_temperature: 0
        })

      {:noreply, _state} = Inverter.handle_info(:loop, state)
      assert D.equal?(Emitter.get(emitter, & &1["requested_torque"]), maximum)
    end
  end
end
