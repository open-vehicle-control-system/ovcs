defmodule Mix.Tasks.VisionCore.NxCache do
  @shortdoc "Builds the module cache of a vehicle's Nx stereo code"

  @moduledoc """
  Compiles a vehicle's Nx stereo code into a module cache directory,
  which a device that cannot compile, such as the OKdo Nano C100, loads
  instead:

      mix vision_core.nx_cache --composer Roomba.Vision.Composer --out priv/nx_iree_cache

  Run it in the vehicle's project, on the host, where `vision_firmware`
  brings EXLA. It reads the `:stereo` component of the composer's
  `config(:target)` and compiles, with the compiler and flags of its
  `:defn_options`, everything the pipeline compiles when it starts (see
  `VisionCore.Stereo.NxSegment.build_cache/2`). The cache keys each
  module on the stages, their options and the size: run it again after
  changing any of them. A calibration change needs no new module.
  """
  use Mix.Task

  alias VisionCore.Stereo.{NxSegment, Supervisor}

  @switches [composer: :string, out: :string]

  @impl Mix.Task
  def run(args) do
    {parsed, _rest} = OptionParser.parse!(args, strict: @switches)
    composer = Module.concat([fetch!(parsed, :composer)])
    dir = Path.expand(fetch!(parsed, :out))

    Mix.Task.run("compile")
    {:ok, _apps} = Application.ensure_all_started([:exla, :nx_iree])

    pipeline_opts = composer |> stereo_options() |> Supervisor.pipeline_options()

    case NxSegment.build_cache(pipeline_opts, dir) do
      :ok -> Mix.shell().info("#{inspect(composer)}'s Nx stereo code cached in #{dir}")
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp stereo_options(composer) do
    %VisionCore.Config{components: components} = composer.config(:target)

    Enum.find_value(components, fn
      {:stereo, options} -> options
      _component -> nil
    end) || Mix.raise("#{inspect(composer)} has no :stereo component")
  end

  defp fetch!(parsed, key),
    do: Keyword.get(parsed, key) || Mix.raise("--#{key} is required")
end
