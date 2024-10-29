defmodule ROSBridgeFirmwareTest do
  use ExUnit.Case
  doctest ROSBridgeFirmware

  test "greets the world" do
    assert ROSBridgeFirmware.hello() == :world
  end
end
