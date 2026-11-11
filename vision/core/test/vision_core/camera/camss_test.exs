defmodule VisionCore.Camera.CamssTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Camss

  @fixtures Path.expand("../../fixtures/camss", __DIR__)

  # Answers `media-ctl -p` with `fixture` and records every command.
  defp runner(fixture) do
    test = self()
    text = File.read!(Path.join(@fixtures, fixture))

    fn command, args ->
      send(test, {:ran, command, args})
      if "-p" in args, do: {text, 0}, else: {"", 0}
    end
  end

  test "parses entities, their device nodes and links" do
    graph = Camss.parse(File.read!(Path.join(@fixtures, "media-ctl-p.txt")))

    assert graph.entities["msm_vfe1_video0"].devnode == "/dev/video5"
    assert graph.entities["imx296 7-001a"].devnode == "/dev/v4l-subdev41"

    assert %{source_pad: 0, sink_pad: 0, enabled: true, immutable: true} =
             Enum.find(graph.links, &(&1.source == "imx296 7-001a" and &1.sink == "msm_csiphy1"))
  end

  test "routes the sensor linked to a CSI PHY whatever its bus number" do
    for {fixture, sensor} <- [
          {"media-ctl-p.txt", "imx296 7-001a"},
          {"media-ctl-p-renumbered.txt", "imx296 5-001a"}
        ] do
      assert {:ok, %{sensor: ^sensor, video: "/dev/video" <> _, subdev: "/dev/v4l-subdev" <> _}} =
               Camss.route(1, runner: runner(fixture))

      assert_received {:ran, "media-ctl", ["-d", "/dev/media0", "-p"]}
      assert_received {:ran, "media-ctl", ["-d", "/dev/media0", "-l", links]}
      assert links =~ ~s("msm_csiphy1":1->"msm_csid1":0[1])
      assert links =~ ~s("msm_csid1":1->"msm_vfe1_rdi0":0[1])

      assert_received {:ran, "media-ctl", ["-d", "/dev/media0", "-V", formats]}
      assert formats == ~s("#{sensor}":0[fmt:SRGGB10_1X10/1456x1088])

      assert_received {:ran, "media-ctl", ["-d", "/dev/media0", "-V", formats]}

      for pad <- ~w(msm_csiphy1 msm_csid1 msm_vfe1_rdi0),
          do: assert(formats =~ ~s("#{pad}":0[fmt:SRGGB10_1X10/1456x1088]))
    end
  end

  test "disables the links that feed the CSID or the RDI from elsewhere" do
    text =
      Path.join(@fixtures, "media-ctl-p.txt")
      |> File.read!()
      |> String.replace(~s(-> "msm_csid1":0 []), ~s(-> "msm_csid1":0 [ENABLED]), global: false)

    test = self()

    runner = fn command, args ->
      send(test, {:ran, command, args})
      if "-p" in args, do: {text, 0}, else: {"", 0}
    end

    assert {:ok, _} = Camss.route(1, runner: runner)
    assert_received {:ran, "media-ctl", ["-d", "/dev/media0", "-l", links]}
    assert links =~ ~s("msm_csiphy0":1->"msm_csid1":0[0])
  end

  test "a CSI PHY without a sensor is an error naming it" do
    assert {:error, message} =
             Camss.route(2, runner: runner("media-ctl-p-no-csiphy2-sensor.txt"))

    assert message =~ "msm_csiphy2"
  end

  test "waits up to :await milliseconds for a media device that is not there yet" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    text = File.read!(Path.join(@fixtures, "media-ctl-p.txt"))

    runner = fn _command, args ->
      if "-p" in args and Agent.get_and_update(attempts, &{&1, &1 + 1}) < 2,
        do: {"Failed to enumerate /dev/media0 (-2)", 1},
        else: {text, 0}
    end

    assert {:error, _} = Camss.route(1, runner: runner)
    Agent.update(attempts, fn _ -> 0 end)
    assert {:ok, %{sensor: "imx296 7-001a"}} = Camss.route(1, runner: runner, await: 2_000)
  end

  test "waits up to :await milliseconds for the sensor to join the graph" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    early = File.read!(Path.join(@fixtures, "media-ctl-p-no-csiphy2-sensor.txt"))
    late = File.read!(Path.join(@fixtures, "media-ctl-p.txt"))

    runner = fn _command, args ->
      cond do
        "-p" not in args -> {"", 0}
        Agent.get_and_update(attempts, &{&1, &1 + 1}) < 2 -> {early, 0}
        true -> {late, 0}
      end
    end

    assert {:ok, %{sensor: "imx477 3-001a"}} = Camss.route(2, runner: runner, await: 2_000)
  end

  test "a media-ctl that fails is an error with its output" do
    runner = fn _command, _args -> {"Failed to enumerate /dev/media0 (-2)", 1} end

    assert {:error, message} = Camss.route(0, runner: runner)
    assert message =~ "Failed to enumerate"
  end
end
