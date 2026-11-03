# Nx stages on Nx's evaluator take minutes per frame; EXLA compiles them for the CPU.
# CI runs `mix test --no-start`, so its client is started here.
{:ok, _apps} = Application.ensure_all_started(:exla)
Application.put_env(:vision_core, :nx_defn_options, compiler: EXLA)

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

# The Ports the tests run, built from the Rust workspace: jpeg_codec
# (VisionCore.Jpeg) for the :jpeg tests, stereo_match (VisionCore.Stereo.Matcher)
# for the :stereo_match tests. CI fails rather than skip them.
rust_workspace = Path.expand("../../rust", __DIR__)
ci? = System.get_env("CI") == "true"

port_tests =
  case System.cmd(
         "cargo",
         ["build", "-q", "--release", "-p", "jpeg_codec", "-p", "stereo_match"],
         cd: rust_workspace,
         stderr_to_stdout: true
       ) do
    {_output, 0} ->
      for {key, binary} <- [jpeg_codec_path: "jpeg_codec", stereo_match_path: "stereo_match"] do
        Application.put_env(
          :vision_core,
          key,
          Path.join(rust_workspace, "target/release/#{binary}")
        )
      end

      []

    {output, _status} when ci? ->
      raise "the Ports did not build:\n" <> output

    {output, _status} ->
      IO.puts("the Ports did not build, skipping the :jpeg and :stereo_match tests:\n" <> output)
      [:jpeg, :stereo_match]
  end

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
