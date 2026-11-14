defmodule VisionCore.Ros2.Bag.MetadataTest do
  @moduledoc """
  The fixtures are the `metadata.yaml` files `ros2 bag record -s mcap` wrote
  in the `ros:lyrical-ros-base` image, rosbag2 0.33.3, whose `yaml.hpp`,
  `qos.cpp` and `bag_metadata.hpp` are those of 0.33.4: `/speed`
  (std_msgs/Float64) and `/tf_static` (tf2_msgs/TFMessage) from
  `ros2 topic pub`, `--max-bag-duration 1` for four files, a topic nobody
  published for none, and `--custom-data` for the quoting of its values.
  """
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.Bag.Metadata

  @fixtures Path.expand("../../../fixtures/rosbag2", __DIR__)

  @float64_hash "RIHS01_705ba9c3d1a09df43737eb67095534de36fd426c0587779bda2bc51fe790182a"
  @tf_message_hash "RIHS01_e369d0f05a23ae52508854b66f6aa0437f3449d652e8cbf22d5abe85d020f087"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
  defp encode(metadata), do: metadata |> Metadata.encode() |> IO.iodata_to_binary()

  defp speed(message_count) do
    %{
      name: "/speed",
      type: "std_msgs/msg/Float64",
      type_description_hash: @float64_hash,
      offered_qos_profiles: [Metadata.publisher_qos()],
      message_count: message_count
    }
  end

  test "encodes two topics in one file as rosbag2 does" do
    tf_static = %{
      name: "/tf_static",
      type: "tf2_msgs/msg/TFMessage",
      type_description_hash: @tf_message_hash,
      offered_qos_profiles: [%{Metadata.publisher_qos() | durability: "transient_local"}],
      message_count: 103
    }

    metadata = %{
      files: [
        %{
          path: "0_fixture_bag_2026_11_14-21_47_16.mcap",
          starting_time: 1_794_692_836_584_071_159,
          duration: 4_636_427_398,
          message_count: 196
        }
      ],
      topics: [speed(93), tf_static],
      custom_data: %{},
      ros_distro: "lyrical"
    }

    assert encode(metadata) == fixture("two_topics.yaml")
  end

  test "encodes four files, the bag's start and duration spanning them" do
    files =
      for {path, starting_time, duration, message_count} <- [
            {"0_split_bag_2026_11_14-21_48_09.mcap", 1_794_692_889_512_996_946, 950_361_547, 20},
            {"1_split_bag_2026_11_14-21_48_10.mcap", 1_794_692_890_513_181_802, 999_603_203, 21},
            {"2_split_bag_2026_11_14-21_48_11.mcap", 1_794_692_891_563_223_602, 999_573_162, 21},
            {"3_split_bag_2026_11_14-21_48_12.mcap", 1_794_692_892_612_857_691, 499_645_738, 11}
          ] do
        %{
          path: path,
          starting_time: starting_time,
          duration: duration,
          message_count: message_count
        }
      end

    metadata = %{
      files: files,
      topics: [speed(73)],
      custom_data: %{"preset" => "replay", "clock" => "since_start"},
      ros_distro: "lyrical"
    }

    assert encode(metadata) == fixture("four_files.yaml")
  end

  test "encodes a bag without messages, its start the largest time rosbag2 has" do
    metadata = %{
      files: [
        %{
          path: "0_empty_bag_2026_11_14-21_48_13.mcap",
          starting_time: nil,
          duration: 0,
          message_count: 0
        }
      ],
      topics: [],
      custom_data: %{},
      ros_distro: "lyrical"
    }

    assert encode(metadata) == fixture("empty.yaml")
  end

  test "quotes custom data as yaml-cpp does" do
    custom_data =
      Map.new([
        {"ws", "a b"},
        {"dropped:/a/b", "3"},
        {"brack", "[x]"},
        {"sp", " lead"},
        {"at", "@x"},
        {"tr", "trail "},
        {"json", ~s({"x":1})},
        {"star", "*x"},
        {"lead", "-x"},
        {"dq", ~s(say"hi")},
        {"hash", "a #b"},
        {"uni", "été"},
        {"colon", "a:b"},
        {"colonspace", "a: b"},
        {"nul", "null"},
        {"f", "1.5"},
        {"y", "yes"},
        {"slash", "/camera/left"},
        {"b", "true"},
        {"v", "0.1.0"},
        {"n", "10"}
      ])

    metadata = %{
      files: [
        %{
          path: "0_quoting_bag_2026_11_14-21_54_16.mcap",
          starting_time: nil,
          duration: 0,
          message_count: 0
        }
      ],
      topics: [],
      custom_data: custom_data,
      ros_distro: "lyrical"
    }

    # rosbag2 writes its custom data in its hash map's order, this module in its keys'.
    assert custom_data_lines(encode(metadata)) ==
             custom_data_lines(fixture("custom_data.yaml"))
             |> Enum.reject(&String.starts_with?(&1, ["q:", "tilde:"]))
  end

  test "publisher_qos/0 is reliable, volatile, keep-last 10, the other policies as rosbag2 wrote them" do
    assert Metadata.publisher_qos() == %{
             history: "keep_last",
             depth: 10,
             reliability: "reliable",
             durability: "volatile",
             deadline: %{sec: 9_223_372_036, nsec: 854_775_807},
             lifespan: %{sec: 9_223_372_036, nsec: 854_775_807},
             liveliness: "automatic",
             liveliness_lease_duration: %{sec: 9_223_372_036, nsec: 854_775_807},
             avoid_ros_namespace_conventions: false
           }
  end

  test "encode_qos_profiles/1 is the channel metadata rosbag2's MCAP storage writes" do
    assert Metadata.encode_qos_profiles([Metadata.publisher_qos()]) ==
             "- history: keep_last\n  depth: 10\n  reliability: reliable\n  durability: volatile\n" <>
               "  deadline:\n    sec: 9223372036\n    nsec: 854775807\n" <>
               "  lifespan:\n    sec: 9223372036\n    nsec: 854775807\n" <>
               "  liveliness: automatic\n" <>
               "  liveliness_lease_duration:\n    sec: 9223372036\n    nsec: 854775807\n" <>
               "  avoid_ros_namespace_conventions: false"
  end

  defp custom_data_lines(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "  custom_data:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "    "))
    |> Enum.map(&String.trim_leading/1)
    |> Enum.sort()
  end
end
