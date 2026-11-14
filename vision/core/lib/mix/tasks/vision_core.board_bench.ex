defmodule Mix.Tasks.VisionCore.BoardBench do
  @shortdoc "Times the stereo stages on a vision board against EXLA"
  @moduledoc """
  Compiles the stereo stages for a vision board on this machine, copies
  them to the board with a textured pair of frames and EXLA's outputs
  for it, and runs them there with `VisionCore.Stereo.Bench`: prints how
  each output differs from EXLA's, the time of each pair, and a `BENCH`
  line of medians, the GPU's busy time per pair among them.

      mix vision_core.board_bench --host 192.168.1.50 [--key ~/.ssh/id_ed25519]
        [--composer <Vehicle>.Vision.Composer] [--board ventuno_q]
        [--size 728x544] [--frame 728x544]
        [--disparities 128] [--search coarse_to_fine] [--paths 8] [--coarse-paths 3]
        [--set stage.setting=value ...] [--drop stage,stage]
        [--pairs 10] [--compute nx|native] [--hot] [--ssh-option OPTION ...]

  `--composer` times the stages of the composer's `:stereo` component,
  with their options, at its working and frame sizes: what the unit
  runs. Run it in the vehicle's project, as `mix vision_core.nx_cache`.
  Without it, the default stages run at 728x544, Disparity over 128
  disparities, coarse to fine, along 8 paths. `--disparities`,
  `--search`, `--paths` and `--coarse-paths` change those Disparity
  options; `--size` and `--frame` the sizes.

  Each `--set stage.setting=value` changes a setting of a stage, by the
  stage's name (`disparity`, `speckle_filter`) and the setting's, as
  `GET /api/stages` lists them. `--drop` leaves out the stages it names.

  The board runs the vision firmware and accepts SSH with `--key`; each
  `--ssh-option` is passed to `ssh` and `sftp` as `-o`. The
  live stereo unit stops while the benchmark runs, so the GPU is the
  benchmark's, and restarts after it.

  `--compute native` computes the stages in the board's `stereo_match`, on
  its CPU, instead of compiling them for its GPU; the coarse-to-fine
  search has no native matcher, so give it `--search full`.

  `--hot` also loads this project's `nx_stereo` modules on the board, its
  shaders among them, so a change to them is measured without building a
  firmware. The live unit then stays stopped, as its module cache was
  compiled for the firmware's `nx_stereo`: reboot the board to run the
  firmware again.
  """

  use Mix.Task

  alias VisionCore.Stereo.{Bench, Pipeline, Supervisor}

  @remote_dir "/data/bench"
  @default_size "728x544"
  @default_disparity [num_disparities: 128, search: "coarse_to_fine", paths: 8]
  @switches [
    host: :string,
    key: :string,
    composer: :string,
    board: :string,
    size: :string,
    frame: :string,
    disparities: :integer,
    search: :string,
    paths: :integer,
    coarse_paths: :integer,
    set: :keep,
    drop: :string,
    pairs: :integer,
    hot: :boolean,
    compute: :string,
    ssh_option: :keep
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    host = opts[:host] || Mix.raise("--host is required")
    Mix.Task.run("app.config")
    for app <- [:exla, :nx_iree], do: {:ok, _} = Application.ensure_all_started(app)

    dir = Path.join(System.tmp_dir!(), "vision_core_board_bench")
    File.rm_rf!(dir)
    :ok = Bench.prepare(dir, bench_options(opts))

    beams = Path.join(dir, "beams")
    File.mkdir_p!(beams)
    for beam <- beams(opts[:hot]), do: File.cp!(beam, Path.join(beams, Path.basename(beam)))
    copy(dir, host, opts)
    Mix.shell().info(remote(host, opts, expression(opts[:hot])))
  end

  defp bench_options(opts) do
    unit = unit(opts[:composer])
    size = if opts[:size], do: dimensions(opts[:size]), else: unit.size
    frame_size = if opts[:frame], do: dimensions(opts[:frame]), else: unit.frame_size || size

    [
      board: opts[:board] || "ventuno_q",
      size: size,
      frame_size: frame_size,
      stages: unit.stages,
      disparity: Keyword.merge(unit.disparity, disparity_flags(opts)),
      overrides: ok!(Bench.parse_overrides(Keyword.get_values(opts, :set), unit.stages)),
      drop: ok!(Bench.parse_stage_names(stage_names(opts[:drop]), unit.stages)),
      pairs: opts[:pairs] || 10,
      compute: compute(opts[:compute])
    ]
  end

  # The stages, their Disparity defaults and the sizes, the composer's or the default ones.
  defp unit(nil) do
    %{
      stages: Pipeline.default_stages(),
      disparity: @default_disparity,
      size: dimensions(@default_size),
      frame_size: nil
    }
  end

  defp unit(composer_name) do
    pipeline = composer_name |> composer!() |> stereo_options!() |> Supervisor.pipeline_options()

    %{
      stages: Keyword.fetch!(pipeline, :stages),
      disparity: [],
      size: {Keyword.fetch!(pipeline, :width), Keyword.fetch!(pipeline, :height)},
      frame_size:
        {Keyword.fetch!(pipeline, :frame_width), Keyword.fetch!(pipeline, :frame_height)}
    }
  end

  defp composer!(name) do
    composer = Module.concat([name])

    Code.ensure_loaded?(composer) ||
      Mix.raise("no module #{name}: run the task in the vehicle's project")

    composer
  end

  defp stereo_options!(composer) do
    %VisionCore.Config{components: components} = composer.config(:target)

    Enum.find_value(components, fn
      {:stereo, options} -> options
      _component -> nil
    end) || Mix.raise("#{inspect(composer)} has no :stereo component")
  end

  defp disparity_flags(opts) do
    for {flag, setting} <- [
          disparities: :num_disparities,
          search: :search,
          paths: :paths,
          coarse_paths: :coarse_paths
        ],
        Keyword.has_key?(opts, flag),
        do: {setting, Keyword.fetch!(opts, flag)}
  end

  defp stage_names(nil), do: []
  defp stage_names(names), do: String.split(names, ",")

  defp ok!({:ok, parsed}), do: parsed
  defp ok!({:error, reason}), do: Mix.raise(reason)

  defp compute(nil), do: :nx
  defp compute("nx"), do: :nx
  defp compute("native"), do: :native
  defp compute(other), do: Mix.raise("--compute is nx or native, got #{inspect(other)}")

  defp dimensions(text) do
    [width, height] = text |> String.split("x") |> Enum.map(&String.to_integer/1)
    {width, height}
  end

  # The benchmark's module, and with --hot nx_stereo's.
  defp beams(hot?) do
    ebin = &Path.join([Mix.Project.build_path(), "lib", &1, "ebin"])
    bench = Path.join(ebin.("vision_core"), "Elixir.VisionCore.Stereo.Bench.beam")
    [bench | if(hot?, do: Path.wildcard(Path.join(ebin.("nx_stereo"), "*.beam")), else: [])]
  end

  defp copy(dir, host, opts) do
    files = Path.wildcard(Path.join(dir, "**/*")) |> Enum.reject(&File.dir?/1)
    folders = ["cache", "beams"]

    batch =
      ["-rm #{@remote_dir}/*/*", "-rm #{@remote_dir}/*", "-mkdir #{@remote_dir}"] ++
        Enum.map(folders, &"-mkdir #{@remote_dir}/#{&1}") ++
        Enum.map(files, &"put #{&1} #{@remote_dir}/#{Path.relative_to(&1, dir)}")

    batch_file = Path.join(dir, "sftp.batch")
    File.write!(batch_file, Enum.join(batch, "\n") <> "\n")

    case System.cmd("sftp", ssh_options(opts) ++ ["-b", batch_file, host], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("copying to #{host} failed:\n" <> output)
    end
  end

  defp expression(hot?) do
    restart =
      if hot?,
        do:
          ~s|IO.puts("The live stereo unit stays stopped: reboot the board to run its firmware.")|,
        else: "Supervisor.restart_child(VisionCore.Supervisor, VisionCore.Stereo.Supervisor)"

    """
    for beam <- Path.wildcard("#{@remote_dir}/beams/*.beam") do
      module = beam |> Path.basename(".beam") |> String.to_atom()
      :code.purge(module)
      {:module, _} = :code.load_abs(String.to_charlist(Path.rootname(beam)))
    end
    Supervisor.terminate_child(VisionCore.Supervisor, VisionCore.Stereo.Supervisor)
    try do
      IO.puts(VisionCore.Stereo.Bench.run("#{@remote_dir}"))
    after
      #{restart}
    end
    :ok
    """
  end

  defp remote(host, opts, expression) do
    case System.cmd("ssh", ssh_options(opts) ++ ["-o", "BatchMode=yes", host, expression],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {output, _} -> Mix.raise("running on #{host} failed:\n" <> output)
    end
  end

  defp ssh_options(opts) do
    identity =
      if opts[:key], do: ["-i", Path.expand(opts[:key]), "-o", "IdentitiesOnly=yes"], else: []

    identity ++ Enum.flat_map(Keyword.get_values(opts, :ssh_option), &["-o", &1])
  end
end
