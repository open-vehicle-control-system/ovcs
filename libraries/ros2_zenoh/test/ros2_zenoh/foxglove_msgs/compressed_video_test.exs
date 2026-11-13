defmodule Ros2Zenoh.FoxgloveMsgs.CompressedVideoTest do
  @moduledoc """
  Byte-equality against `test/support/golden_cdr.json` for
  `foxglove_msgs/CompressedVideo`, one frame of a camera's H.264 stream.

  Its `format` string comes after the `data` byte run, so the string's
  length prefix re-aligns to 4 after it: the vectors cover data lengths
  of each residue modulo 4 and an empty frame. They were validated by
  deserialising them with `foxglove_msgs` on a real ROS 2 runtime; see
  `test/support/golden_cdr.md`.
  """
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp video(data) do
    %CompressedVideo{
      timestamp: %Time{sec: 1_735_689_600, nanosec: 123_456_789},
      frame_id: "center_optical",
      data: data,
      format: "h264"
    }
  end

  for length <- [0, 5, 6, 7, 8] do
    test "a frame of #{length} bytes" do
      data = :binary.copy(<<0xA5>>, unquote(length))

      assert CompressedVideo.encode(video(data)) == golden("compressed_video_#{unquote(length)}")
    end
  end

  test "is published as foxglove_msgs/CompressedVideo, at the priority of images" do
    assert CompressedVideo.dds_type() == "foxglove_msgs::msg::dds_::CompressedVideo_"

    assert CompressedVideo.type_hash() ==
             "RIHS01_32039eafc3770e589c86c4dabff9c392ce9955ebffd43f5f60763011d43d8d1d"

    assert Ros2Zenoh.priority(CompressedVideo) == :data_low
  end
end
