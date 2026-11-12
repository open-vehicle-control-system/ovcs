defmodule VisionCore.Detection.QnnContextTest do
  use ExUnit.Case, async: true

  alias VisionCore.Detection.QnnContext

  @moduletag :tmp_dir

  @executable "/priv/qnn_detect"

  # A QAIRT directory holding only libQnnHtp.so, and a runner that answers the Port's
  # `--graph-names` with `graph_names`, writes the binary the generator would and counts its
  # runs.
  defp setup_qairt(dir, library) do
    qairt = Path.join(dir, "qairt")
    File.mkdir_p!(Path.join(qairt, "lib"))
    File.write!(Path.join(qairt, "lib/libQnnHtp.so"), library)
    qairt
  end

  defp runner(test, graph_names) do
    fn
      @executable, ["--graph-names", dlc], _env ->
        send(test, {:graph_names, dlc})
        graph_names

      command, args, env ->
        send(test, {:generated, command, args, env})
        opts = args |> Enum.chunk_every(2) |> Map.new(fn [flag, value] -> {flag, value} end)
        File.write!(Path.join(opts["--output_dir"], opts["--binary_file"] <> ".bin"), "context")
        {"", 0}
    end
  end

  defp ensure(dlc, qairt, cache, graph_names \\ {"graph_a\n", 0}) do
    QnnContext.ensure(dlc,
      qairt_dir: qairt,
      dsp_library_path: "/dsp",
      cache_dir: cache,
      executable: @executable,
      runner: runner(self(), graph_names)
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

  test "a binary cached under a key without the HTP graph options is generated again", %{
    tmp_dir: dir
  } do
    qairt = setup_qairt(dir, "library")
    cache = Path.join(dir, "cache")
    dlc = Path.join(dir, "model.dlc")
    File.write!(dlc, "model")
    File.mkdir_p!(cache)

    old_key =
      :crypto.hash(:sha256, ["model", "library"])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    old = Path.join(cache, old_key <> ".bin")
    File.write!(old, "context at the default optimisation level")

    assert {:ok, binary} = ensure(dlc, qairt, cache)
    assert binary != old
    assert_received {:generated, _, _, _}
    refute File.exists?(old)
  end

  test "the generator prepares the DLC's graphs at optimisation level 3 through the HTP backend extensions",
       %{tmp_dir: dir} do
    qairt = setup_qairt(dir, "library")
    cache = Path.join(dir, "cache")
    dlc = Path.join(dir, "model.dlc")
    File.write!(dlc, "model")

    assert {:ok, _binary} = ensure(dlc, qairt, cache, {"graph_a\ngraph_b\n", 0})
    assert_received {:graph_names, ^dlc}
    assert_received {:generated, _, args, _}
    assert ["--config_file", config] = Enum.take(args, -2)
    assert config == Path.join(cache, "backend_config.json")

    htp_config = Path.join(cache, "htp_backend_extensions.json")

    assert Jason.decode!(File.read!(config)) == %{
             "backend_extensions" => %{
               "shared_library_path" => Path.join(qairt, "lib/libQnnHtpNetRunExtensions.so"),
               "config_file_path" => htp_config
             }
           }

    assert Jason.decode!(File.read!(htp_config)) == %{
             "graphs" => [%{"graph_names" => ["graph_a", "graph_b"], "O" => 3}]
           }
  end

  test "a DLC whose graph names cannot be read is an error, and the generator does not run", %{
    tmp_dir: dir
  } do
    qairt = setup_qairt(dir, "library")
    dlc = Path.join(dir, "model.dlc")
    File.write!(dlc, "model")

    assert {:error, {:graph_names_failed, 1, "no DLC"}} = ensure(dlc, qairt, dir, {"no DLC", 1})
    assert {:error, {:no_graph_names, ^dlc}} = ensure(dlc, qairt, dir, {"", 0})
    refute_received {:generated, _, _, _}
  end

  test "a missing DLC or QAIRT is an error, and nothing runs", %{tmp_dir: dir} do
    qairt = setup_qairt(dir, "library")
    dlc = Path.join(dir, "model.dlc")

    assert {:error, {:missing_dlc, ^dlc}} = ensure(dlc, qairt, dir)
    File.write!(dlc, "model")
    assert {:error, {:missing_qairt, _}} = ensure(dlc, Path.join(dir, "none"), dir)
    refute_received {:generated, _, _, _}
    refute_received {:graph_names, _}
  end
end
