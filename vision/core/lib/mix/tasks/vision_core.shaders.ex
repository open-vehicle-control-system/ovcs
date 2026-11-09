defmodule Mix.Tasks.VisionCore.Shaders do
  @shortdoc "Compiles the stereo stages' Vulkan shaders into priv/spirv"
  @moduledoc """
  Compiles the GLSL sources in `shaders/` into the SPIR-V binaries
  `VisionCore.Stereo.Kernels` embeds, one per kernel variant it lists,
  into `priv/spirv`. Requires `glslangValidator`; the binaries are
  committed, so building vision_core does not.

      mix vision_core.shaders
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    compiler =
      System.find_executable("glslangValidator") || Mix.raise("glslangValidator not found")

    File.mkdir_p!("priv/spirv")

    for {kernel, {source, flags}} <- VisionCore.Stereo.Kernels.variants() do
      output = "priv/spirv/#{kernel}.spv"

      args =
        ~w(-V --target-env vulkan1.1 -S comp) ++ flags ++ ["-o", output, "shaders/#{source}.comp"]

      case System.cmd(compiler, args, stderr_to_stdout: true) do
        {_, 0} -> Mix.shell().info("compiled #{output}")
        {log, _} -> Mix.raise("glslangValidator failed on #{source}:\n" <> log)
      end
    end
  end
end
