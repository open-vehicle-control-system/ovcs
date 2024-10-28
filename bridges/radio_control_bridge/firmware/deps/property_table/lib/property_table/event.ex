defmodule PropertyTable.Event do
  @moduledoc """
  Struct sent to subscribers on property changes

  * `:table` - the table generating this event
  * `:property` - which property changed
  * `:value` - the new value
  * `:timestamp` - the timestamp (`System.monotonic_time/0`) when the changed
    happened
  * `:previous_value` - the previous value (`nil` if this property is new)
  * `:previous_timestamp` - the timestamp when the property changed to
    `:previous_value`. Use this to calculate how long the property was the
    previous value.
  """
  defstruct [:table, :property, :value, :timestamp, :previous_value, :previous_timestamp]

  @type t() :: %__MODULE__{
          table: PropertyTable.table_id(),
          property: PropertyTable.property(),
          value: PropertyTable.value(),
          previous_value: PropertyTable.value(),
          timestamp: integer(),
          previous_timestamp: integer()
        }

  @doc """
  Convert event to the old tuple event format

  This is only used for backwards compatibility. At some point, it hopefully
  will be removed.
  """
  @spec to_tuple(t()) ::
          {PropertyTable.table_id(), PropertyTable.property(), PropertyTable.value(),
           PropertyTable.value(), %{new_timestamp: integer, old_timestamp: integer}}
  def to_tuple(%__MODULE__{} = event) do
    {event.table, event.property, event.previous_value, event.value,
     %{old_timestamp: event.previous_timestamp, new_timestamp: event.timestamp}}
  end
end
