defmodule VmsCore.PubSub.CommandMessage do
  defstruct [
    :name,
    :value,
    :previous_value,
    :source
  ]
end
