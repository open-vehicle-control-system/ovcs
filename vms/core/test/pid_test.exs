defmodule VmsCoreTest do
  use ExUnit.Case
  doctest VmsCore
  alias VmsCore.PID
  alias Decimal, as: D

  @zero D.new(0)
  @one D.new(1)

  test "new/1 creates a new PID" do
    assert %PID{} = PID.new()
  end

  test "proportional control" do
    pid = PID.new(kp: D.new("0.2")) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(D.new("0.2"))
  end

  test "initial derivative term should be zero" do
    pid = PID.new(kd: D.new(1)) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(0)
  end

  test "initial integral term should be based on the minimum elapsed time" do
    pid = PID.new(ki: D.new("0.25")) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?("0.000025")
  end

  test "output is capped by the maximum output value" do
    pid = PID.new(kp: D.new("2"), minimum_output: D.new(-5), maximum_output: D.new(-2)) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(-2)
  end

  test "output is capped by the minimum output value" do
    pid = PID.new(kp: D.new("2"), minimum_output: D.new(5), maximum_output: D.new(10)) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(5)
  end
end
