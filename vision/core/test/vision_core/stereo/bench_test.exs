defmodule VisionCore.Stereo.BenchTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.Bench

  @moduletag :vulkan
  @moduletag :tmp_dir

  test "a prepared benchmark runs from its cache and matches EXLA's outputs", %{tmp_dir: dir} do
    :ok =
      Bench.prepare(dir,
        board: "c100",
        size: {192, 108},
        disparity: [num_disparities: 64, paths: 3],
        pairs: 3
      )

    assert [_ | _] = Path.wildcard(Path.join([dir, "cache", "*"]))
    report = Bench.run(dir)

    for key <- ~w(left right disparity depth cloud),
        do: assert(report =~ ~r/^#{key}: 0\/\d+ differ/m, report)

    assert [_, times] = Regex.run(~r/us per pair: \[([^\]]*)\]/, report)
    assert times |> String.split(", ") |> length() == 3
  end

  @tag :stereo_match
  test "a native benchmark computes the stages in stereo_match, as EXLA does", %{tmp_dir: dir} do
    :ok =
      Bench.prepare(dir,
        board: "ventuno_q",
        compute: :native,
        size: {192, 108},
        disparity: [num_disparities: 64, paths: 3],
        pairs: 2
      )

    assert Path.wildcard(Path.join([dir, "cache", "*"])) == []
    report = Bench.run(dir)

    for key <- ~w(left right disparity depth cloud),
        do: assert(report =~ ~r/^#{key}: 0\/\d+ differ/m, report)

    assert report =~ "us per pair: ["
  end
end
