defmodule VisionCore.Parameters.Group do
  @moduledoc """
  A component or pipeline stage and its parameters, as `VisionCore.Parameters`
  lists it. `:placement` is where the dashboard draws it: `:flow` in the
  pipeline, `:side` beside it. `:summary` is one line on what it does;
  `:explanation`, when given, a paragraph for someone tuning it: what it
  does, why it matters, what its settings change and what to watch.
  `:compute` is where a stage runs and what it is written in, `nil` for a
  group that does not say.
  """
  alias VisionCore.Parameters.Parameter

  defstruct [
    :id,
    :name,
    :summary,
    :explanation,
    :kind,
    :placement,
    :position,
    :status,
    :compute,
    parameters: []
  ]

  @typedoc """
  Where a group's work runs (`:cpu` or `:gpu`), what it is written in
  (`:nx`, `:rust` or `:elixir`) and, for Nx, what compiles it (`:vulkan`
  or `:llvm_cpu` through `nx_iree`, `:exla`, or Nx's `:evaluator`).
  """
  @type compute :: %{
          runs_on: :cpu | :gpu,
          implementation: :nx | :rust | :elixir,
          backend: :vulkan | :llvm_cpu | :exla | :evaluator | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          summary: String.t(),
          explanation: String.t() | nil,
          kind: :component | :stage,
          placement: :flow | :side,
          position: non_neg_integer(),
          status: {:ok | :warning | :off, String.t()} | nil,
          compute: compute() | nil,
          parameters: [Parameter.t()]
        }
end
