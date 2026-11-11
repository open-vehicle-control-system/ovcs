# Nx stages on Nx's evaluator take minutes per frame; EXLA compiles them for the CPU.
# CI runs `mix test --no-start`, so its client is started here.
{:ok, _apps} = Application.ensure_all_started(:exla)
Application.put_env(:vision_core, :nx_defn_options, compiler: EXLA)

# A segment that misses its deadline leaves its EXLA computation running in a dirty NIF, and
# halting the VM under it crashes XLA's threads: the suite ends once the dirty schedulers are idle.
ExUnit.after_suite(fn _results ->
  normal_run_queues = :erlang.system_info(:schedulers)

  dirty_busy? = fn ->
    :erlang.statistics(:active_tasks_all) |> Enum.drop(normal_run_queues) |> Enum.sum() > 0
  end

  Enum.reduce_while(1..600, :ok, fn _attempt, :ok ->
    if dirty_busy?.(), do: {:cont, Process.sleep(100)}, else: {:halt, :ok}
  end)
end)

# The saved parameter values' database: one file per run, removed after it.
database = Application.fetch_env!(:vision_core, VisionCore.Repo)[:database]
remove_database = fn -> Enum.each(["", "-wal", "-shm"], &File.rm(database <> &1)) end
remove_database.()
ExUnit.after_suite(fn _results -> remove_database.() end)

{:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _pid} = VisionCore.Repo.start_link()
Ecto.Migrator.run(VisionCore.Repo, :up, all: true, log: false)

# The outputs registry, which VisionCore.Supervisor starts on a vehicle, for the
# producers and consumers the tests start on their own.
{:ok, _pid} = VisionCore.Outputs.start_link()

# The Ports the tests run: jpeg_codec (VisionCore.Jpeg), built from the Rust
# workspace, for the :jpeg tests, and the stereo_match nx_stereo builds when
# it compiles (VisionCore.Stereo.Matcher) for the :stereo_match tests. CI
# fails rather than skip them.
rust_workspace = Path.expand("../../rust", __DIR__)
ci? = System.get_env("CI") == "true"

jpeg_tests =
  case System.cmd("cargo", ["build", "-q", "--release", "-p", "jpeg_codec"],
         cd: rust_workspace,
         stderr_to_stdout: true
       ) do
    {_output, 0} ->
      path = Path.join(rust_workspace, "target/release/jpeg_codec")
      Application.put_env(:vision_core, :jpeg_codec_path, path)
      []

    {output, _status} when ci? ->
      raise "jpeg_codec did not build:\n" <> output

    {output, _status} ->
      IO.puts("jpeg_codec did not build, skipping the :jpeg tests:\n" <> output)
      [:jpeg]
  end

stereo_match_tests =
  cond do
    File.exists?(NxStereo.Matcher.default_path()) ->
      Application.put_env(:vision_core, :stereo_match_path, NxStereo.Matcher.default_path())
      []

    ci? ->
      raise "nx_stereo built no stereo_match: is cargo installed?"

    true ->
      IO.puts("nx_stereo built no stereo_match, skipping the :stereo_match tests")
      [:stereo_match]
  end

port_tests = jpeg_tests ++ stereo_match_tests

# The :rust tests build and run the Rust workspace: in CI, or with `--include rust`.
# The :vulkan tests need a Vulkan device, which CI runners do not have, and
# the :iree tests run the IREE compiler; run them with `--include vulkan`
# or `--include iree`.
rust_tests = if ci?, do: [], else: [:rust]

# A message another process sends may come late while the async tests and EXLA compiles share
# the schedulers; an assert_receive waits only until it comes.
ExUnit.start(
  exclude: rust_tests ++ [:vulkan, :iree | port_tests],
  assert_receive_timeout: 1_000
)
