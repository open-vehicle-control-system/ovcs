defmodule VmsCore.Components.Nissan.LeafAZE0.InverterTest do
  @moduledoc """
  The inverter's temperatures: Fahrenheit on the wire, Celsius on the
  bus.
  """
  use ExUnit.Case, async: true
  alias Cantastic.{Frame, FrameSpecification}
  alias Decimal, as: D
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter

  @frame_path "can/components/nissan/leaf_aze0/0x55A_inverter_temperatures.yml"

  defp frame_specification do
    {:ok, yaml} =
      :ovcs_can
      |> :code.priv_dir()
      |> Path.join(@frame_path)
      |> YamlElixir.read_from_file(atoms: true)

    yaml = yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms)
    {:ok, specification} = FrameSpecification.from_yaml(:leaf_drive, yaml, :receive)
    specification
  end

  defp received_frame(raw_data) do
    frame = %Frame{id: 0x55A, network_name: :leaf_drive, raw_data: raw_data, byte_number: 8}
    {:ok, frame} = Frame.interpret(frame, frame_specification())
    frame
  end

  test "the frame labels its temperatures in Fahrenheit" do
    units = frame_specification().signal_specifications |> Enum.map(& &1.unit) |> Enum.uniq()
    assert units == ["°F"]
  end

  test "each temperature is converted from Fahrenheit to Celsius" do
    # 32 °F, 212 °F, 50 °F and 122 °F.
    frame = received_frame(<<0, 32, 212, 50, 122, 0, 0, 0>>)

    {:noreply, state} =
      Inverter.handle_info(
        {:handle_frame, frame},
        %{
          inverter_communication_board_temperature: nil,
          insulated_gate_bipolar_transistor_temperature: nil,
          insulated_gate_bipolar_transistor_board_temperature: nil,
          motor_temperature: nil
        }
      )

    assert D.equal?(state.inverter_communication_board_temperature, 0)
    assert D.equal?(state.insulated_gate_bipolar_transistor_temperature, 100)
    assert D.equal?(state.insulated_gate_bipolar_transistor_board_temperature, 10)
    assert D.equal?(state.motor_temperature, 50)
  end
end
