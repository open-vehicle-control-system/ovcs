defmodule VmsCore.Bus.Message do
  @moduledoc """
    A VMS Bus Message
  """
  defstruct [
    :name,
    :value,
    :source
  ]
end
