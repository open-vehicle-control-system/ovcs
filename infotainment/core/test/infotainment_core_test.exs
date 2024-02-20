defmodule InfotainmentCoreTest do
  use ExUnit.Case
  doctest InfotainmentCore

  test "greets the world" do
    assert InfotainmentCore.hello() == :world
  end
end
