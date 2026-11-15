defmodule VisionCore.Ros2.Bag.Metadata do
  @moduledoc """
  A rosbag2 folder's `metadata.yaml`, as ROS 2 Lyrical's rosbag2 writes it:
  version 9, `storage_identifier: mcap`, no rosbag2 compression (MCAP
  compresses its chunks), the bag's start, duration and message count over
  its files, each topic with its type, `cdr`, the QoS profiles its publishers
  offered, its type hash and message count, each file with its own, and the
  custom data, in yaml-cpp's block style: two-space indents, sequences
  indented under their key, `~` for no custom data, no final newline.

  Sources, rosbag2 0.33.4:

    * `convert<BagMetadata>`, `convert<TopicMetadata>` and
      `convert<FileInformation>` in
      [`rosbag2_storage/include/rosbag2_storage/yaml.hpp`](https://github.com/ros2/rosbag2/blob/0.33.4/rosbag2_storage/include/rosbag2_storage/yaml.hpp),
      the fields and their order; version 9's decoder reads every one of them.
    * `convert<rclcpp::QoS>` in
      [`rosbag2_storage/src/rosbag2_storage/qos.cpp`](https://github.com/ros2/rosbag2/blob/0.33.4/rosbag2_storage/src/rosbag2_storage/qos.cpp),
      a QoS profile's fields, policies by name from version 9.
    * `SequentialWriter::init_metadata` in
      [`rosbag2_cpp/src/rosbag2_cpp/writers/sequential_writer.cpp`](https://github.com/ros2/rosbag2/blob/0.33.4/rosbag2_cpp/src/rosbag2_cpp/writers/sequential_writer.cpp),
      the start of a bag or file without messages, the largest signed 64-bit
      time.

  The tests compare it with files `ros2 bag record` wrote in Lyrical.
  """

  @no_start 9_223_372_036_854_775_807
  @infinite %{sec: 9_223_372_036, nsec: 854_775_807}

  @type duration :: %{sec: non_neg_integer(), nsec: non_neg_integer()}

  @type qos :: %{
          history: String.t(),
          depth: non_neg_integer(),
          reliability: String.t(),
          durability: String.t(),
          deadline: duration(),
          lifespan: duration(),
          liveliness: String.t(),
          liveliness_lease_duration: duration(),
          avoid_ros_namespace_conventions: boolean()
        }

  @typedoc "A file, its path relative to the folder, its times in nanoseconds; `nil` without messages."
  @type file_information :: %{
          path: String.t(),
          starting_time: non_neg_integer() | nil,
          duration: non_neg_integer(),
          message_count: non_neg_integer()
        }

  @type topic :: %{
          name: String.t(),
          type: String.t(),
          type_description_hash: String.t(),
          offered_qos_profiles: [qos()],
          message_count: non_neg_integer()
        }

  @typep yaml_node ::
           [{String.t(), yaml_node()}]
           | {:sequence, [yaml_node()]}
           | String.t()
           | integer()
           | boolean()
           | nil

  @type t :: %{
          files: [file_information()],
          topics: [topic()],
          custom_data: %{String.t() => String.t()},
          ros_distro: String.t()
        }

  @doc "The `metadata.yaml` of a bag."
  @spec encode(t()) :: iodata()
  def encode(metadata), do: emit([{"rosbag2_bagfile_information", bag(metadata)}])

  @doc """
  The QoS profile the vision core's publishers offer
  (`Ros2Zenoh.RmwZenoh.liveliness_key/5`: reliable, volatile, keep-last 10),
  with the deadline, lifespan, liveliness and lease `ros2 bag record` wrote
  in Lyrical for a publisher that leaves them to their defaults.
  """
  @spec publisher_qos() :: qos()
  def publisher_qos do
    %{
      history: "keep_last",
      depth: 10,
      reliability: "reliable",
      durability: "volatile",
      deadline: @infinite,
      lifespan: @infinite,
      liveliness: "automatic",
      liveliness_lease_duration: @infinite,
      avoid_ros_namespace_conventions: false
    }
  end

  @doc """
  QoS profiles as rosbag2's MCAP storage writes them in a channel's
  `offered_qos_profiles` metadata (`serialize_rclcpp_qos_vector` in `qos.cpp`).
  """
  @spec encode_qos_profiles([qos()]) :: String.t()
  def encode_qos_profiles(profiles), do: emit({:sequence, Enum.map(profiles, &qos_node/1)})

  defp bag(metadata) do
    {starting_time, duration} = span(metadata.files)

    [
      {"version", 9},
      {"storage_identifier", "mcap"},
      {"duration", [{"nanoseconds", duration}]},
      {"starting_time", [{"nanoseconds_since_epoch", starting_time}]},
      {"message_count", metadata.topics |> Enum.map(& &1.message_count) |> Enum.sum()},
      {"topics_with_message_count", {:sequence, Enum.map(metadata.topics, &topic_node/1)}},
      {"compression_format", ""},
      {"compression_mode", ""},
      {"relative_file_paths", {:sequence, Enum.map(metadata.files, & &1.path)}},
      {"files", {:sequence, Enum.map(metadata.files, &file_node/1)}},
      {"custom_data", custom_data_node(metadata.custom_data)},
      {"ros_distro", metadata.ros_distro}
    ]
  end

  defp span(files) do
    case for(%{starting_time: start} = file <- files, start != nil, do: file) do
      [] ->
        {@no_start, 0}

      files ->
        start = files |> Enum.map(& &1.starting_time) |> Enum.min()
        ending = files |> Enum.map(&(&1.starting_time + &1.duration)) |> Enum.max()
        {start, ending - start}
    end
  end

  defp topic_node(topic) do
    [
      {"topic_metadata",
       [
         {"name", topic.name},
         {"type", topic.type},
         {"serialization_format", "cdr"},
         {"offered_qos_profiles", {:sequence, Enum.map(topic.offered_qos_profiles, &qos_node/1)}},
         {"type_description_hash", topic.type_description_hash}
       ]},
      {"message_count", topic.message_count}
    ]
  end

  defp qos_node(qos) do
    [
      {"history", qos.history},
      {"depth", qos.depth},
      {"reliability", qos.reliability},
      {"durability", qos.durability},
      {"deadline", duration_node(qos.deadline)},
      {"lifespan", duration_node(qos.lifespan)},
      {"liveliness", qos.liveliness},
      {"liveliness_lease_duration", duration_node(qos.liveliness_lease_duration)},
      {"avoid_ros_namespace_conventions", qos.avoid_ros_namespace_conventions}
    ]
  end

  defp duration_node(%{sec: sec, nsec: nsec}), do: [{"sec", sec}, {"nsec", nsec}]

  defp file_node(file) do
    [
      {"path", file.path},
      {"starting_time", [{"nanoseconds_since_epoch", file.starting_time || @no_start}]},
      {"duration", [{"nanoseconds", file.duration}]},
      {"message_count", file.message_count}
    ]
  end

  defp custom_data_node(custom_data) when map_size(custom_data) == 0, do: nil
  defp custom_data_node(custom_data), do: Enum.sort(custom_data)

  @spec emit(yaml_node()) :: String.t()
  defp emit(node), do: node |> lines(0) |> Enum.join("\n")

  defp lines({:sequence, items}, indent), do: Enum.flat_map(items, &item_lines(&1, indent))

  defp lines(entries, indent) when is_list(entries),
    do: Enum.flat_map(entries, &entry_lines(&1, indent))

  defp entry_lines({key, value}, indent) do
    prefix = String.duplicate(" ", indent) <> scalar(key) <> ":"

    case value do
      {:sequence, []} -> [prefix, String.duplicate(" ", indent + 2) <> "[]"]
      {:sequence, _items} -> [prefix | lines(value, indent + 2)]
      [_entry | _entries] -> [prefix | lines(value, indent + 2)]
      scalar -> [prefix <> " " <> scalar(scalar)]
    end
  end

  # An item's first line starts with its dash, the rest at its indent.
  defp item_lines(entries, indent) when is_list(entries) do
    [first | rest] = lines(entries, indent + 2)
    [String.duplicate(" ", indent) <> "- " <> String.trim_leading(first) | rest]
  end

  defp item_lines(scalar, indent), do: [String.duplicate(" ", indent) <> "- " <> scalar(scalar)]

  defp scalar(nil), do: "~"
  defp scalar(boolean) when is_boolean(boolean), do: Atom.to_string(boolean)
  defp scalar(integer) when is_integer(integer), do: Integer.to_string(integer)

  defp scalar(string) when is_binary(string) do
    if plain?(string), do: string, else: double_quoted(string)
  end

  # yaml-cpp's `IsValidPlainScalar` in block context (`src/emitterutils.cpp`).
  defp plain?(string) do
    string not in ["", "~", "null", "Null", "NULL"] and
      not String.starts_with?(string, String.graphemes(" ,[]{}#&*!|>'\"%@`")) and
      not Regex.match?(~r/\A[-?:](\s|\z)/, string) and
      not String.ends_with?(string, [" ", ":"]) and
      not String.contains?(string, [": ", " #"]) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, string)
  end

  defp double_quoted(string) do
    escaped =
      for <<char::utf8 <- string>>, into: "" do
        case char do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\t -> "\\t"
          char when char < 0x20 -> "\\x" <> Base.encode16(<<char>>, case: :lower)
          char -> <<char::utf8>>
        end
      end

    "\"" <> escaped <> "\""
  end
end
