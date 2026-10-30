defmodule VisionCore.Parameters.Parameter do
  @moduledoc """
  A vision parameter as `VisionCore.Parameters` lists it: what it accepts,
  its value when listed, its built-in default, its saved value and its state.
  """
  alias VisionCore.Parameters

  defstruct [
    :id,
    :group,
    :name,
    :type,
    :constraint,
    :applies,
    :greater_than,
    :description,
    :default,
    :value,
    :saved,
    :state,
    :export
  ]

  @type t :: %__MODULE__{
          id: Parameters.id(),
          group: String.t(),
          name: String.t(),
          type: Parameters.type(),
          constraint: Parameters.constraint() | nil,
          applies: Parameters.applies(),
          greater_than: Parameters.id() | nil,
          description: String.t() | nil,
          default: term(),
          value: term(),
          saved: term(),
          state: Parameters.state(),
          export: [atom()] | nil
        }
end
