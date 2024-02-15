defmodule VmsCoreTest do
  use ExUnit.Case
  doctest VmsCore

  test "greets the world" do
    assert VmsCore.hello() == :world
  end
end
