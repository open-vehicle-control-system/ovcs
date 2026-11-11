defmodule VisionCore.Detection.QnnContextTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection.QnnContext

  @moduletag :tmp_dir

  # A QAIRT directory holding only libQnnHtp.so, and a runner that writes the
  # binary the generator would and counts its runs.
  defp setup_qairt(dir, library) do
    qairt = Path.join(dir, "qairt")
    File.mkdir_p!(Path.join(qairt, "lib"))
    File.write!(Path.join(qairt, "lib/libQnnHtp.so"), library)
    qairt
  end

  defp runner(test) do
    fn command, args, env ->
      send(test, {:generated, command, args, env})
      opts = args |> Enum.chunk_every(2) |> Map.new(fn [flag, value] -> {flag, value} end)
      File.write!(Path.join(opts["--output_dir"], opts["--binary_file"] <> ".bin"), "context")
      {"", 0}
    end
  end

  defp ensure(dlc, qairt, cache) do
    QnnContext.ensure(dlc,
      qairt_dir: qairt,
      dsp_library_path: "/dsp",
      cache_dir: cache,
      runner: runner(self())
    )
  end

  test "the cache key changes with the DLC or libQnnHtp.so", %{tmp_dir: dir} do
    qairt = setup_qairt(dir, "library one")
    cache = Path.join(dir, "cache")
    dlc = Path.join(dir, "model.dlc")
    File.write!(dlc, "model one")

    assert {:ok, first} = ensure(dlc, qairt, cache)
    assert_received {:generated, generator, args, env}
    assert generator == Path.join(qairt, "bin/qnn-context-binary-generator")
    assert ["--backend", backend, "--dlc_path", ^dlc | _] = args
    assert backend == Path.join(qairt, "lib/libQnnHtp.so")
    assert {"ADSP_LIBRARY_PATH", "#{qairt}/lib/hexagon-v75/unsigned;/dsp"} in env

    assert {:ok, ^first} = ensure(dlc, qairt, cache)
    refute_received {:generated, _, _, _}

    File.write!(dlc, "model two")
    assert {:ok, second} = ensure(dlc, qairt, cache)
    assert second != first
    assert_received {:generated, _, _, _}
    refute File.exists?(first)

    File.write!(Path.join(qairt, "lib/libQnnHtp.so"), "library two")
    assert {:ok, third} = ensure(dlc, qairt, cache)
    assert third not in [first, second]
  end

  test "a missing DLC or QAIRT is an error, and nothing runs", %{tmp_dir: dir} do
    qairt = setup_qairt(dir, "library")
    dlc = Path.join(dir, "model.dlc")

    assert {:error, {:missing_dlc, ^dlc}} = ensure(dlc, qairt, dir)
    File.write!(dlc, "model")
    assert {:error, {:missing_qairt, _}} = ensure(dlc, Path.join(dir, "none"), dir)
    refute_received {:generated, _, _, _}
  end
end
