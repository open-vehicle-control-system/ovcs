defmodule VisionCore.Camera.RustFramingTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, LibCamera}

  @moduletag :rust

  @rust_workspace Path.expand("../../../../rust", __DIR__)

  test "LibCamera parses the records the Rust framing crate writes" do
    {output, 0} =
      System.cmd("cargo", ["run", "-q", "-p", "framing", "--example", "dump"],
        cd: @rust_workspace
      )

    assert [frame, log, metadata] = split_packets(output)

    assert {:ok, %Frame{width: 640, height: 480, jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>}} =
             LibCamera.parse_record(frame)

    assert {:log, :warning, "hello"} = LibCamera.parse_record(log)

    assert {:metadata, reported} = LibCamera.parse_record(metadata)

    assert %{
             exposure_time_us: 1000,
             digital_gain: 1.0,
             frame_duration_us: 33_333,
             sync_ready: true
           } = reported

    refute Map.has_key?(reported, :analogue_gain)
    refute Map.has_key?(reported, :lens_position)
    refute Map.has_key?(reported, :colour_temperature)
    refute Map.has_key?(reported, :sync_timer_us)
  end

  defp split_packets(<<>>), do: []

  defp split_packets(<<length::32, record::binary-size(length), rest::binary>>),
    do: [record | split_packets(rest)]
end
