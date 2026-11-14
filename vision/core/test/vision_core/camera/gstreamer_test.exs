defmodule VisionCore.Camera.GStreamerTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{Frame, GStreamer}
  alias VisionCore.Outputs

  test "publishes each JPEG of the stream as a frame under its label, with its frame id" do
    output = {:camera_frame, GStreamer.name_for("left")}
    :ok = Outputs.subscribe(output)

    state = %{
      label: "left",
      frame_id: "stereo_left_optical",
      width: 2,
      height: 2,
      port: :port,
      buffer: <<>>,
      output: output
    }

    jpeg = <<0xFF, 0xD8, 1, 2, 0xFF, 0xD9>>

    assert {:noreply, %{buffer: <<0xFF, 0xD8>>}} =
             GStreamer.handle_info({:port, {:data, jpeg <> <<0xFF, 0xD8>>}}, state)

    assert_receive {:"$gen_cast",
                    {:camera_frame,
                     %Frame{label: "left", frame_id: "stereo_left_optical", jpeg: ^jpeg}}}
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a pipeline that exits is started again by the same driver, whose frames come back",
       %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "gst-launch-1.0")

    File.write!(executable, """
    #!/bin/sh
    dir=$(dirname "$0")
    printf x >> "$dir/runs"
    [ "$(wc -c < "$dir/runs")" -le 3 ] && exit 1
    (while printf '\\377\\330\\001\\377\\331' 2> /dev/null; do sleep 0.02; done) &
    cat > /dev/null
    """)

    File.chmod!(executable, 0o755)
    :ok = Outputs.subscribe({:camera_frame, GStreamer.name_for("glitch")})

    camera =
      start_supervised!(
        {GStreamer,
         label: "glitch", device: "/dev/null", executable: executable, reopen_delays_ms: [10]}
      )

    assert_receive {:"$gen_cast", {:camera_frame, %Frame{label: "glitch"}}}, 5_000
    assert File.read!(Path.join(tmp_dir, "runs")) == "xxxx"
    assert Process.whereis(GStreamer.name_for("glitch")) == camera
    assert VisionCore.Camera.Reopen.running?(camera)
  end
end
