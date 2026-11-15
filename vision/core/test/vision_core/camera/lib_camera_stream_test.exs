defmodule VisionCore.Camera.LibCameraStreamTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.{Frame, LibCamera, LibCameraStream, Output}
  alias VisionCore.Outputs

  @outputs [
    half: [resolution: {1152, 648}, processor: :isp, send: false],
    half_jpeg: [from: :half, format: :jpeg, quality: 80]
  ]

  @side LibCamera.name_for("stereo/left")

  defp start_stream(opts \\ []) do
    start_supervised!(
      {LibCameraStream,
       [
         name: :left,
         label: "left",
         frame_id: "left_optical",
         stream_of: :left,
         side_label: "stereo/left",
         outputs: @outputs
       ] ++ opts}
    )
  end

  defp side_frame(output) do
    %Frame{
      label: "stereo/left",
      frame_id: "stereo_left_optical",
      output: output,
      width: 1152,
      height: 648,
      capture_ns: 42,
      jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>
    }
  end

  describe "outputs/1" do
    test "resolves the camera's outputs, the JPEG its default" do
      assert {:ok, [%Output{name: :half, processor: :isp, send: false}, half_jpeg]} =
               LibCameraStream.outputs(outputs: @outputs)

      assert %Output{name: :half_jpeg, format: :jpeg, quality: 80, send: true} = half_jpeg
    end

    test "refuses a camera without outputs" do
      assert LibCameraStream.outputs([]) ==
               {:error, "it names its :outputs, which the stereo side's capture makes"}
    end

    test "refuses outputs it cannot resolve" do
      assert {:error, "outputs are a keyword list" <> _} = LibCameraStream.outputs(outputs: :half)

      assert {:error, "output half: its processor :cpu is not one this driver has (:isp)"} =
               LibCameraStream.outputs(
                 outputs: [half: [resolution: {1152, 648}, processor: :cpu]]
               )
    end
  end

  test "has no controls of its own: the sensor's are the stereo unit's" do
    Code.ensure_loaded!(LibCameraStream)

    for function <- [control_specs: 0, set_controls: 2, controls: 1, live: 1] do
      refute function_exported?(LibCameraStream, elem(function, 0), elem(function, 1))
    end
  end

  test "publishes the side's output frames under its own keys, with its label and frame id" do
    start_stream()
    :ok = Outputs.subscribe({:camera_frame, LibCameraStream.name_for("left"), :half_jpeg})

    Outputs.publish({:camera_frame, @side, :half_jpeg}, {:camera_frame, side_frame(:half_jpeg)})

    assert_receive {:"$gen_cast", {:camera_frame, frame}}, 1_000

    assert %Frame{
             label: "left",
             frame_id: "left_optical",
             output: :half_jpeg,
             width: 1152,
             height: 648,
             capture_ns: 42
           } = frame
  end

  test "takes none of the side's grey frames" do
    start_stream()
    :ok = Outputs.subscribe({:camera_frame, LibCameraStream.name_for("left"), :half_jpeg})

    Outputs.publish({:camera_frame, @side}, {:camera_frame, %{side_frame(nil) | jpeg: nil}})

    refute_receive {:"$gen_cast", {:camera_frame, _frame}}, 200
  end

  test "refuses to start without the stereo side's label, which the wiring gives" do
    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {LibCameraStream, name: :left, label: "left", stream_of: :left, outputs: @outputs}
             )

    assert message =~ "VisionCore.Components.wire_streams!/1"
  end

  describe "running?/1" do
    @describetag :tmp_dir

    test "is false while the side's driver is not registered" do
      stream = start_stream()
      refute LibCameraStream.running?(stream)
    end

    test "follows the side's capture program", %{tmp_dir: tmp_dir} do
      stream = start_stream()
      exits = Path.join(tmp_dir, "exits")
      File.write!(exits, "#!/bin/sh\nexit 3\n")
      File.chmod!(exits, 0o755)
      idle = Path.join(tmp_dir, "idle")
      File.write!(idle, "#!/bin/sh\nexec cat > /dev/null\n")
      File.chmod!(idle, 0o755)

      side =
        start_supervised!(
          {LibCamera,
           label: "stereo/left", camera_id: 0, executable: idle, reopen_delays_ms: [60_000]}
        )

      assert LibCameraStream.running?(stream)

      stop_supervised!(LibCamera)

      start_supervised!(
        {LibCamera,
         label: "stereo/left", camera_id: 0, executable: exits, reopen_delays_ms: [60_000]}
      )

      refute side == Process.whereis(@side)
      assert eventually(fn -> not LibCameraStream.running?(stream) end)
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end
end
