# Prints one raw `sensor_msgs/Imu` payload from `/imu_probe` as a hex
# literal for a test fixture. Needs an rclpy publisher on that topic and
# a Zenoh router on 127.0.0.1:7447: `mix run --no-start scripts/capture_imu_bytes.exs`.

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

IO.puts("Subscribed to 0/imu_probe/** — waiting for a sample...")

receive do
  %Zenohex.Sample{key_expr: key_expr, payload: payload} ->
    IO.puts("Got sample on #{key_expr} (#{byte_size(payload)} bytes total)")
    {:ok, body} = Ros2Zenoh.RmwZenoh.decode_payload(payload)
    IO.puts("Body (post CDR header strip): #{byte_size(body)} bytes")
    IO.puts("")
    IO.puts("hex_literal = <<")

    body
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.each(fn chunk ->
      hexes =
        Enum.map_join(
          chunk,
          ", ",
          &("0x" <> String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
        )

      IO.puts("  " <> hexes <> ",")
    end)

    IO.puts(">>")
    IO.puts("")

    case Ros2Zenoh.SensorMsgs.Msg.Imu.parse(body) do
      {:ok, parsed, rest} ->
        IO.puts("Parse succeeded; rest = #{byte_size(rest)} bytes")
        IO.puts("parsed: " <> inspect(parsed, pretty: true))

      error ->
        IO.puts("PARSE FAILED: " <> inspect(error))
    end
after
  10_000 ->
    IO.puts("Timed out waiting for a sample.")
    System.halt(1)
end
