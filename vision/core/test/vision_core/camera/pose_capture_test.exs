defmodule VisionCore.Camera.PoseCaptureTest do
  # Subscribes and publishes under the cameras' output keys.
  use ExUnit.Case, async: false

  alias VisionCore.Camera.{Frame, PoseCapture}
  alias VisionCore.Debug.Png
  alias VisionCore.Outputs

  @moduletag :tmp_dir

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # A stereo unit at 20 pairs a second, half a period 25 ms, and a camera :hq.
  defp config do
    %VisionCore.Config{
      components: [
        {:stereo, driver: Camera, fps: 20, left: [], right: []},
        {:camera, name: :hq, driver: Camera}
      ]
    }
  end

  defp left_frame(capture_ms),
    do: %Frame{
      label: "left",
      width: 2,
      height: 2,
      capture_ns: capture_ms * 1_000_000,
      grey: <<capture_ms, 1, 2, 3>>
    }

  defp camera_frame(capture_ms),
    do: %Frame{
      label: "hq",
      width: 1,
      height: 2,
      capture_ns: capture_ms * 1_000_000,
      rgb: <<capture_ms, 0, 0, 0, 0, 255>>
    }

  # Runs `capture/2` aside, then hands it `frames` once it listens to both cameras.
  defp capture_with(frames, options) do
    task = Task.async(fn -> PoseCapture.capture(:hq, [config: config()] ++ options) end)

    for name <- ["left", "hq"],
        do:
          eventually(fn -> Outputs.subscribers({:camera_frame, Camera.name_for(name)}) != [] end)

    for %Frame{label: label} = frame <- frames,
        do: Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})

    Task.await(task)
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(5) && eventually(check, attempts - 1)
    end
  end

  test "saves the left frame and the camera's frame closest in capture time, as PNG", %{
    tmp_dir: tmp_dir
  } do
    frames = [left_frame(0), left_frame(50), camera_frame(40)]

    assert {:ok, saved} = capture_with(frames, directory: tmp_dir, timeout_ms: 1_000)

    assert saved.left == Path.join(tmp_dir, "left-0000.png")
    assert saved.camera == Path.join(tmp_dir, "camera-0000.png")
    assert saved.offset_ms == 10.0

    assert {:ok, %{colour: :grey, width: 2, height: 2, pixels: <<50, 1, 2, 3>>}} =
             saved.left |> File.read!() |> Png.decode()

    assert {:ok, %{colour: :rgb, width: 1, height: 2, pixels: <<40, 0, 0, 0, 0, 255>>}} =
             saved.camera |> File.read!() |> Png.decode()
  end

  test "numbers each pair after those already in the directory", %{tmp_dir: tmp_dir} do
    {:ok, _first} = capture_with([left_frame(0), camera_frame(5)], directory: tmp_dir)
    {:ok, second} = capture_with([left_frame(100), camera_frame(110)], directory: tmp_dir)

    assert Path.basename(second.left) == "left-0001.png"
    assert Path.basename(second.camera) == "camera-0001.png"
  end

  test "keeps a JPEG frame as it is", %{tmp_dir: tmp_dir} do
    jpeg = %{camera_frame(10) | rgb: nil, jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>}

    {:ok, saved} = capture_with([left_frame(0), jpeg], directory: tmp_dir)

    assert saved.camera == Path.join(tmp_dir, "camera-0000.jpg")
    assert File.read!(saved.camera) == <<0xFF, 0xD8, 0xFF, 0xD9>>
  end

  test "pairs no frames further apart than half a stereo period", %{tmp_dir: tmp_dir} do
    frames = [left_frame(0), camera_frame(26), left_frame(60)]

    assert capture_with(frames, directory: tmp_dir, timeout_ms: 200) ==
             {:error, :no_matching_pair}

    assert File.ls!(tmp_dir) == []
  end

  test "leaves no subscription behind", %{tmp_dir: tmp_dir} do
    {:ok, _saved} =
      capture_with([left_frame(0), camera_frame(1), camera_frame(2)], directory: tmp_dir)

    assert Outputs.subscribers({:camera_frame, Camera.name_for("left")}) == []
    assert Outputs.subscribers({:camera_frame, Camera.name_for("hq")}) == []
  end

  test "refuses a camera or a stereo unit the configuration does not have" do
    assert PoseCapture.capture(:usb, config: config()) == {:error, {:no_camera, :usb}}

    no_stereo = %VisionCore.Config{components: [{:camera, name: :hq, driver: Camera}]}
    assert PoseCapture.capture(:hq, config: no_stereo) == {:error, :no_stereo_unit}
  end
end
