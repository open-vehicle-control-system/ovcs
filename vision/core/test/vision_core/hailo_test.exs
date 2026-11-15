defmodule VisionCore.HailoTest do
  use ExUnit.Case, async: false

  alias VisionCore.Hailo
  alias VisionCore.Inference.PortBackend

  @moduletag :tmp_dir
  @moduletag :capture_log

  @executable Path.expand("../support/fake_hailo.py", __DIR__)
  @image Nx.iota({2, 3}, type: :u8)
  @band %{width: 2, height: 1, rgb: <<1, 2, 3, 4, 5, 6>>}

  defp hef(tmp_dir, name, mode) do
    path = Path.join(tmp_dir, name)
    File.write!(path, mode)
    path
  end

  defp start_hailo(tmp_dir, networks) do
    start_supervised!(
      {Hailo,
       networks ++
         [
           executable: @executable,
           working_directory: tmp_dir,
           library_path: tmp_dir,
           reopen_delays_ms: [20]
         ]}
    )
  end

  defp eventually(check, attempts \\ 300) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "runs every network in one program, each on the lane of its pipeline", %{tmp_dir: tmp_dir} do
    objects = hef(tmp_dir, "objects.hef", "answer")
    road = hef(tmp_dir, "road.hef", "answer")

    server =
      start_hailo(tmp_dir,
        networks: [
          objects: [kind: :detection, hef_path: objects],
          road: [kind: :segmentation, hef_path: road, classes: 19]
        ]
      )

    eventually(fn -> PortBackend.available?(server) end)

    assert PortBackend.submit(server, :objects, 1, @image) == :ok
    assert PortBackend.submit(server, :road, 2, @band) == :ok

    assert_receive {:inference_detections, 1, [%{class_id: 0, x1: 3.0, y1: 2.0}]}
    assert_receive {:inference_labels, 2, %{width: 2, height: 1, data: <<0, 1>>}}
    assert PortBackend.inference_times(server, :objects) == %{sum_us: 1500, count: 1}
    assert PortBackend.inference_times(server, :road) == %{sum_us: 2500, count: 1}

    assert File.read!(objects <> ".starts") == "start\n"
    assert File.read!(objects <> ".arguments") == "--detect #{objects} 0.4 --segment #{road} 8"
  end

  test "runs two networks of one kind side by side, each answering on its own lane", %{
    tmp_dir: tmp_dir
  } do
    people = hef(tmp_dir, "people.hef", "answer")
    signs = hef(tmp_dir, "signs.hef", "answer")

    server =
      start_hailo(tmp_dir,
        networks: [
          people: [kind: :detection, hef_path: people],
          signs: [kind: :detection, hef_path: signs, score_threshold: 0.6]
        ]
      )

    eventually(fn -> PortBackend.available?(server) end)

    assert PortBackend.submit(server, :signs, 1, @image) == :ok
    assert PortBackend.submit(server, :people, 2, @image) == :ok
    assert_receive {:inference_detections, 1, [_detection]}
    assert_receive {:inference_detections, 2, [_detection]}
    assert File.read!(people <> ".arguments") == "--detect #{people} 0.4 --detect #{signs} 0.6"
    assert PortBackend.submit(server, :road, 3, @band) == {:error, :unavailable}
  end

  test "a segmentation in flight does not hold a detection back", %{tmp_dir: tmp_dir} do
    objects = hef(tmp_dir, "objects.hef", "answer")
    road = hef(tmp_dir, "road.hef", "hang")

    server =
      start_hailo(tmp_dir,
        networks: [
          road: [kind: :segmentation, hef_path: road],
          objects: [kind: :detection, hef_path: objects]
        ]
      )

    eventually(fn -> PortBackend.available?(server) end)

    assert PortBackend.submit(server, :road, 1, @band) == :ok
    assert PortBackend.submit(server, :objects, 2, @image) == :ok
    assert_receive {:inference_detections, 2, [_detection]}
    assert PortBackend.submit(server, :road, 3, @band) == {:error, :busy}
  end

  test "stays unavailable without one of its models", %{tmp_dir: tmp_dir} do
    objects = hef(tmp_dir, "objects.hef", "answer")

    server =
      start_hailo(tmp_dir,
        networks: [
          objects: [kind: :detection, hef_path: objects],
          road: [kind: :segmentation, hef_path: Path.join(tmp_dir, "missing.hef")]
        ]
      )

    Process.sleep(100)
    assert PortBackend.state(server) == :failed
    refute File.exists?(objects <> ".starts")
  end

  test "declares the inference step of each pipeline it serves" do
    start_supervised!(VisionCore.Parameters)

    start_hailo(System.tmp_dir!(),
      networks: [
        objects: [kind: :detection, hef_path: "/nowhere/objects.hef"],
        road: [kind: :segmentation, hef_path: "/nowhere/stdc1.hef"]
      ]
    )

    ids = Enum.map(VisionCore.Parameters.groups(), & &1.id)
    assert "objects.inference" in ids
    assert "road.inference" in ids
  end

  test "refuses a start without a network" do
    assert_raise ArgumentError, ~r/no network/, fn -> Hailo.init(networks: []) end
  end
end
