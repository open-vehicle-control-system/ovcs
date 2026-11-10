defmodule Mix.Tasks.VisionCore.BoardBench do
  @shortdoc "Times the default stereo stages on a vision board's GPU against EXLA"
  @moduledoc """
  Compiles the default stereo stages for a vision board on this machine,
  copies them to the board with a textured pair of frames and EXLA's
  outputs for it, and runs them there with `VisionCore.Stereo.Bench`:
  prints how each output differs from EXLA's and the time of each pair.

      mix vision_core.board_bench --host 192.168.1.50 [--key ~/.ssh/id_ed25519]
        [--board ventuno_q] [--size 728x544] [--frame 728x544]
        [--disparities 128] [--search coarse_to_fine] [--paths 8] [--coarse-paths 3]
        [--pairs 10] [--hot] [--ssh-option OPTION ...]

  The board runs the vision firmware and accepts SSH with `--key`; each
  `--ssh-option` is passed to `ssh` and `sftp` as `-o`. The
  live stereo unit stops while the benchmark runs, so the GPU is the
  benchmark's, and restarts after it.

  `--hot` also loads this project's `nx_stereo` modules on the board, its
  shaders among them, so a change to them is measured without building a
  firmware. The live unit then stays stopped, as its module cache was
  compiled for the firmware's `nx_stereo`: reboot the board to run the
  firmware again.
  """

  use Mix.Task

  alias VisionCore.Stereo.Bench

  @remote_dir "/data/bench"
  @switches [
    host: :string,
    key: :string,
    board: :string,
    size: :string,
    frame: :string,
    disparities: :integer,
    search: :string,
    paths: :integer,
    coarse_paths: :integer,
    pairs: :integer,
    hot: :boolean,
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
    size = dimensions(opts[:size] || "728x544")

    :ok =
      Bench.prepare(dir,
        board: opts[:board] || "ventuno_q",
        size: size,
        frame_size: if(opts[:frame], do: dimensions(opts[:frame]), else: size),
        disparity: disparity(opts),
        pairs: opts[:pairs] || 10
      )

    beams = Path.join(dir, "beams")
    File.mkdir_p!(beams)
    for beam <- beams(opts[:hot]), do: File.cp!(beam, Path.join(beams, Path.basename(beam)))
    copy(dir, host, opts)
    Mix.shell().info(remote(host, opts, expression(opts[:hot])))
  end

  defp dimensions(text) do
    [width, height] = text |> String.split("x") |> Enum.map(&String.to_integer/1)
    {width, height}
  end

  defp disparity(opts) do
    [
      num_disparities: opts[:disparities] || 128,
      search: opts[:search] || "coarse_to_fine",
      paths: opts[:paths] || 8
    ] ++ if(opts[:coarse_paths], do: [coarse_paths: opts[:coarse_paths]], else: [])
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
