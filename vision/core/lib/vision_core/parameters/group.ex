defmodule VisionCore.Parameters.Group do
  @moduledoc """
  A component or pipeline stage and its parameters, as `VisionCore.Parameters`
  lists it. `:pipeline` is the pipeline it is a step of, such as `:stereo` or
  `:detection`, which the dashboard draws as one flow. `:summary` is one line
  on what it does; `:explanation`, when given, a paragraph for someone tuning
  it: what it does, why it matters, what its settings change and what to
  watch. `:compute` is where a stage runs and what it is written in, `nil`
  for a group that does not say.
  """
  alias VisionCore.Parameters.Parameter

  defstruct [
    :id,
    :name,
    :summary,
    :explanation,
    :kind,
    :pipeline,
    :position,
    :status,
    :compute,
    parameters: []
  ]

  @typedoc """
  Where a group's work runs (`:cpu`, `:gpu`, or `:npu` for a neural network
  accelerator), what it is written in (`:nx`, `:rust` or `:elixir`) and, for
  Nx, what compiles it (`:vulkan` or `:llvm_cpu` through `nx_iree`, `:exla`,
  or Nx's `:evaluator`).
  """
  @type compute :: %{
          runs_on: :cpu | :gpu | :npu,
          implementation: :nx | :rust | :elixir,
          backend: :vulkan | :llvm_cpu | :exla | :evaluator | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          summary: String.t(),
          explanation: String.t() | nil,
          kind: :component | :stage,
          pipeline: atom(),
          position: non_neg_integer(),
          status: {:ok | :warning | :off, String.t()} | nil,
          compute: compute() | nil,
          parameters: [Parameter.t()]
        }
end
