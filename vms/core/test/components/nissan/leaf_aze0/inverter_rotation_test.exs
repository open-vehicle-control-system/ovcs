defmodule VmsCore.Components.Nissan.LeafAZE0.InverterRotationTest do
  @moduledoc "The inverter's rpm: unsigned, and unknown above the EM57's rated 10,500."
  use ExUnit.Case, async: true
  alias Cantastic.{Frame, Signal}
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter

  defp published(rotation_per_minute) do
    frame = %Frame{
      name: "inverter_status",
      signals: %{
        "inverter_output_voltage" => %Signal{value: 0},
        "effective_torque" => %Signal{value: 0},
        "rotations_per_minute" => %Signal{value: rotation_per_minute}
      }
    }

    state = %{rotation_per_minute: nil, inverter_output_voltage: nil, effective_torque: nil}
    {:noreply, state} = Inverter.handle_info({:handle_frame, frame}, state)
    state.rotation_per_minute
  end

  test "a reading up to the rated maximum is kept" do
    assert published(10_500) == 10_500
  end

  test "a reverse reading is unsigned" do
    assert published(-3_000) == 3_000
  end

  test "a reading above the rated maximum is invalid and unknown" do
    assert published(10_501) == nil
    assert published(-32_768) == nil
  end
end
