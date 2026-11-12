defmodule VisionCore.Segmentation.Backend.StubTest do
  use ExUnit.Case, async: false

  alias VisionCore.Segmentation.Backend.Stub

  @moduletag :capture_log

  @band %{width: 2, height: 1, rgb: <<0, 0, 0, 0, 0, 0>>}

  test "answers every band with its label image, sky above road by default" do
    start_supervised!({Stub, pipeline: :road})

    assert Stub.segment(3, @band) == :ok

    assert_receive {:inference_labels, 3,
                    %{width: 4, height: 2, data: <<10, 10, 10, 10, 0, 0, 0, 0>>}}
  end

  test "answers the label image it is given, under its name, declaring its pipeline's step" do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    labels = %{width: 1, height: 1, data: <<13>>}
    start_supervised!({Stub, name: Stub.Road, pipeline: :road, label_image: labels})

    assert Stub.segment(Stub.Road, 1, @band) == :ok
    assert_receive {:inference_labels, 1, ^labels}

    assert %{position: 102} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))
  end

  test "runs on no accelerator and reports no times" do
    assert Stub.npu_kind() == nil
    assert Stub.inference_times() == nil
  end
end
