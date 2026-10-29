defmodule VisionCore.Stereo.NxStage do
  @moduledoc """
  A `VisionCore.Stereo.Pipeline` stage written in Nx. Like a
  `VisionCore.Stereo.Stage` it has options, `requires/0` and
  `provides/0`, and swaps in a composer's stage list; instead of running
  on a `VisionCore.Stereo.Pair`, it adds its step to a function over
  named tensors.

  At start the pipeline compiles each run of consecutive Nx stages into
  one function, a `VisionCore.Stereo.NxSegment`: a pair's tensors are
  uploaded once, go through every step of the run on the device, and
  come back once.

  The compiled function keeps every value in `state` as a constant, and
  takes `params/2` as inputs: what may change without compiling again,
  such as calibration values, which a calibration reload replaces. Nx
  stages take no runtime settings, since the device cannot compile.
  """

  alias VisionCore.Stereo.{Pair, Stage}

  @type state :: term()

  @doc "Builds the stage's state from its options and the pipeline's context."
  @callback init(opts :: keyword(), Stage.context()) :: {:ok, state()} | {:error, String.t()}

  @doc "The `Pair` fields the stage reads."
  @callback requires() :: [atom()]

  @doc "The `Pair` fields the stage fills, once `finish/3` has run."
  @callback provides() :: [atom()]

  @doc "The compiled function's inputs for this stage: tensors or numbers."
  @callback params(state(), Stage.context()) :: %{atom() => Nx.Tensor.t() | number()}

  @doc """
  Called while tracing: takes the named tensors so far and returns them
  with this stage's outputs added or replaced.
  """
  @callback step(tensors :: map(), params :: map(), state()) :: map()

  @doc """
  Fills the `Pair` from the segment's outputs, on the CPU, after they
  are downloaded. Without it, each output named like a `Pair` field is
  copied there.
  """
  @callback finish(Pair.t(), outputs :: map(), state()) :: Pair.t()

  @optional_callbacks finish: 3

  @doc "Whether `module` is an Nx stage."
  @spec nx_stage?(module()) :: boolean()
  def nx_stage?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :step, 3)
  end
end
