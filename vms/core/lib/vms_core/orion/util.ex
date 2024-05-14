defmodule VmsCore.Orion.Util do
  def counter(value) do
    rem(value, 256)
  end
end
