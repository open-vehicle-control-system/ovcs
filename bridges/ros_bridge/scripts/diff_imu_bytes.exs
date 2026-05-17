# Spike helper #2: captures one rclpy `Imu` sample, encodes the
# *same* struct via our encoder, byte-diffs the two. Used to verify
# CDR alignment is correct end-to-end.

alias Ros2.BuiltinInterfaces.Msg.Time
alias Ros2.GeometryMsgs.Msg.Quaternion
alias Ros2.GeometryMsgs.Msg.Vector3
alias Ros2.SensorMsgs.Msg.Imu
alias Ros2.StdMsgs.Msg.Header

reference =
  %Imu{
    header: %Header{
      stamp: %Time{sec: 1_700_000_000, nanosec: 123_456_789},
      frame_id: "imu_link"
    },
    orientation: %Quaternion{x: 0.1, y: 0.2, z: 0.3, w: :math.sqrt(1.0 - 0.14)},
    orientation_covariance: List.duplicate(0.0, 9),
    angular_velocity: %Vector3{x: 0.4, y: 0.5, z: 0.6},
    angular_velocity_covariance: List.duplicate(0.0, 9),
    linear_acceleration: %Vector3{x: 0.7, y: 0.8, z: 9.81},
    linear_acceleration_covariance: List.duplicate(0.0, 9)
  }

our_bytes = Ros2.SensorMsgs.Msg.Imu.encode(reference)

{:ok, config} = {:ok, Zenohex.Config.default()}
{:ok, config} = Zenohex.Config.insert_json5(config, "mode", "client")

{:ok, config} =
  Zenohex.Config.insert_json5(
    config,
    "connect/endpoints",
    ~s(["tcp/127.0.0.1:7447"])
  )

{:ok, session} = Zenohex.Session.open(config)

{:ok, _subscriber_id} =
  Zenohex.Session.declare_subscriber(session, "0/imu_probe/**", self(), [])

IO.puts("Waiting for one /imu_probe sample…")

receive do
  %Zenohex.Sample{payload: payload} ->
    {:ok, their_bytes} = Ros2.RmwZenoh.decode_payload(payload)

    IO.puts("our_bytes:   #{byte_size(our_bytes)} B")
    IO.puts("their_bytes: #{byte_size(their_bytes)} B")

    if byte_size(our_bytes) != byte_size(their_bytes) do
      IO.puts(IO.ANSI.red() <> "❌ Sizes differ — alignment bug." <> IO.ANSI.reset())
      System.halt(1)
    end

    diffs =
      our_bytes
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(their_bytes))
      |> Enum.with_index()
      |> Enum.reject(fn {{a, b}, _} -> a == b end)

    if diffs == [] do
      IO.puts(IO.ANSI.green() <> "✅ Byte-exact match." <> IO.ANSI.reset())
    else
      IO.puts("Differences (offset | ours → theirs):")

      Enum.each(diffs, fn {{ours, theirs}, offset} ->
        IO.puts(
          "  #{String.pad_leading(Integer.to_string(offset), 4)}  " <>
            "0x#{String.pad_leading(Integer.to_string(ours, 16), 2, "0")} → " <>
            "0x#{String.pad_leading(Integer.to_string(theirs, 16), 2, "0")}"
        )
      end)

      IO.puts("")
      IO.puts("(diffs at known-padding offsets are harmless: CDR readers ignore padding.)")
    end
after
  10_000 ->
    IO.puts("Timed out.")
    System.halt(1)
end
