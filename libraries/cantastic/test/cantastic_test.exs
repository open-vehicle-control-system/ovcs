defmodule CantasticTest do
  use ExUnit.Case
  doctest Cantastic

  test "greets the world" do
    assert Cantastic.hello() == :world
  end
end
