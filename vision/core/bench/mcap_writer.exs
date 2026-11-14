# Throughput and CPU of VisionCore.Mcap.Writer on raw stereo: two mono8 cameras at 30 Hz.
# Run from vision/core: mix run --no-start bench/mcap_writer.exs <output directory>, a directory
# on the disk measured (a tmpfs one measures memory). Each run's file is deleted after it.
defmodule McapWriterBench do
  alias VisionCore.Mcap.Writer

  @width 728
  @height 544
  @rate_hz 30
  @duration_s 60
  @idle_duration_s 20
  @noise_amplitude 4
  # Distinct frames per camera, cycled: far more bytes apart than zstd's window at level 1.
  @frame_pool 8

  def run(directory) do
    File.mkdir_p!(directory)
    frames = frames()

    IO.puts("""
    #{@width}x#{@height} mono8, 2 cameras at #{@rate_hz} Hz for #{@duration_s} s, \
    top-to-bottom gradient plus noise of +/-#{@noise_amplitude}, a chunk per second
    output: #{directory}, #{System.schedulers_online()} schedulers, \
    #{cores()} cores, OTP #{System.otp_release()}
    """)

    idle = measure(fn -> paced(@idle_duration_s * @rate_hz, fn _tick -> :ok end) end)
    IO.puts("idle BEAM, paced at #{@rate_hz} Hz: CPU #{cpu(idle)}\n")

    for compression <- [{:zstd, 1}, :none], pacing <- [:fast, :paced] do
      bench(directory, frames, compression, pacing)
    end
  end

  defp bench(directory, frames, compression, pacing) do
    path = Path.join(directory, "bench.mcap")
    ticks = @duration_s * @rate_hz

    {open_opts, label} =
      case compression do
        {:zstd, level} -> {[compression: :zstd, zstd_level: level], "zstd #{level}"}
        :none -> {[compression: :none], "none"}
      end

    {:ok, writer} = Writer.open(path, open_opts)
    {writer, schema_id} = Writer.add_schema(writer, "sensor_msgs/msg/Image", "ros2msg", "")
    {writer, left} = Writer.add_channel(writer, schema_id, "/stereo/left/image_raw", "cdr", %{})
    {writer, right} = Writer.add_channel(writer, schema_id, "/stereo/right/image_raw", "cdr", %{})
    Process.put(:writer, writer)

    write_tick = fn tick ->
      {left_frame, right_frame} = elem(frames, rem(tick, @frame_pool))
      log_time = System.os_time(:nanosecond)

      writer =
        Process.get(:writer)
        |> Writer.write_message(left, tick, log_time, log_time, left_frame)
        |> Writer.write_message(right, tick, log_time, log_time, right_frame)

      writer = if rem(tick + 1, @rate_hz) == 0, do: Writer.close_chunk(writer), else: writer
      Process.put(:writer, writer)
    end

    run = fn ->
      case pacing do
        :fast -> Enum.each(0..(ticks - 1), write_tick)
        :paced -> paced(ticks, write_tick)
      end

      :ok = Writer.close(Process.get(:writer))
    end

    measured = measure(run)
    input_bytes = ticks * 2 * @width * @height
    file_bytes = File.stat!(path).size
    File.rm!(path)

    IO.puts("""
    #{label}, #{pacing}: #{format_mb(input_bytes)} in #{Float.round(measured.wall_s, 1)} s, \
    #{format_mb(input_bytes / measured.wall_s)}/s in, #{format_mb(file_bytes / measured.wall_s)}/s to the file, \
    file #{format_mb(file_bytes)} (#{Float.round(file_bytes / input_bytes * 100, 1)} % of the input), \
    CPU #{cpu(measured)}
    """)
  end

  defp paced(ticks, tick_fun) do
    start_ms = System.monotonic_time(:millisecond)

    for tick <- 0..(ticks - 1) do
      due_ms = start_ms + div(tick * 1_000, @rate_hz)
      wait_ms = due_ms - System.monotonic_time(:millisecond)
      if wait_ms > 0, do: Process.sleep(wait_ms)
      tick_fun.(tick)
    end
  end

  defp measure(fun) do
    cpu_start = cpu_ticks()
    wall_start = System.monotonic_time(:microsecond)
    fun.()
    wall_s = (System.monotonic_time(:microsecond) - wall_start) / 1_000_000
    %{wall_s: wall_s, cpu_s: (cpu_ticks() - cpu_start) / clock_ticks_per_s()}
  end

  defp cpu(%{wall_s: wall_s, cpu_s: cpu_s}) do
    one_core = cpu_s / wall_s * 100

    "#{Float.round(one_core, 1)} % of a core, #{Float.round(one_core / cores(), 1)} % of #{cores()} cores"
  end

  # utime and stime, the 14th and 15th fields of /proc/self/stat; the 2nd may hold spaces.
  defp cpu_ticks do
    [_pid_and_name, after_name] = File.read!("/proc/self/stat") |> String.split(") ", parts: 2)
    [utime, stime] = after_name |> String.split(" ") |> Enum.slice(11, 2)
    String.to_integer(utime) + String.to_integer(stime)
  end

  # Linux's USER_HZ when getconf is missing, as on Nerves.
  defp clock_ticks_per_s do
    case System.find_executable("getconf") do
      nil ->
        100

      getconf ->
        getconf |> System.cmd(["CLK_TCK"]) |> elem(0) |> String.trim() |> String.to_integer()
    end
  end

  defp cores, do: :erlang.system_info(:logical_processors_online)

  defp format_mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  # A gradient from top to bottom: a diagonal one gives each zstd block every grey level, and
  # zstd stores such noisy blocks uncompressed, which would hide its cost.
  defp frames do
    gradient = for y <- 0..(@height - 1), _x <- 0..(@width - 1), do: div(y * 255, @height - 1)

    List.to_tuple(for _frame <- 1..@frame_pool, do: {noisy(gradient), noisy(gradient)})
  end

  defp noisy(gradient) do
    noise = :binary.bin_to_list(:crypto.strong_rand_bytes(@width * @height))
    span = 2 * @noise_amplitude + 1

    Enum.zip_with(gradient, noise, fn level, random ->
      (level + rem(random, span) - @noise_amplitude) |> max(0) |> min(255)
    end)
    |> :binary.list_to_bin()
  end
end

case System.argv() do
  [directory] ->
    McapWriterBench.run(directory)

  _arguments ->
    IO.puts(:stderr, "usage: mix run --no-start bench/mcap_writer.exs <output directory>")
end
