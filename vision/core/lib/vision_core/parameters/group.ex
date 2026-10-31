defmodule VisionCore.Parameters.Group do
  @moduledoc """
  A component or pipeline stage and its parameters, as `VisionCore.Parameters`
  lists it. `:placement` is where the dashboard draws it: `:flow` in the
  pipeline, `:side` beside it. `:compute` is where a stage runs and what it
  is written in (`t:VisionCore.Stereo.NxSegment.compute/0`), `nil` for a
  group that does not say.
  """
  alias VisionCore.Parameters.Parameter

  defstruct [
    :id,
    :name,
    :summary,
    :kind,
    :placement,
    :position,
    :status,
    :compute,
    parameters: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          summary: String.t(),
          kind: :component | :stage,
          placement: :flow | :side,
          position: non_neg_integer(),
          status: {:ok | :warning | :off, String.t()} | nil,
          compute: VisionCore.Stereo.NxSegment.compute() | nil,
          parameters: [Parameter.t()]
        }
end
