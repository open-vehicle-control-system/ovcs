defmodule OvcsRosBridgeCoreTest do
  use ExUnit.Case
  doctest OvcsRosBridgeCore

  test "greets the world" do
    assert OvcsRosBridgeCore.hello() == :world
  end
end
