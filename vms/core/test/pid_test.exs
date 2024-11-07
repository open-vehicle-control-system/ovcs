defmodule VmsCoreTest do
  use ExUnit.Case
  doctest VmsCore
  alias VmsCore.PID
  alias Decimal, as: D

  @zero D.new(0)
  @one D.new(1)
  @minus_one D.new(-1)

  test "new/1 creates a new PID" do
    assert %PID{} = PID.new()
  end

  test "proportional control with measurement to zero" do
    pid = PID.new(kp: @one) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(@one)
  end

  test "proportional control with measurement halfway" do
    pid = PID.new(kp: @one) |> PID.iterate(D.new("0.5"), @one)
    assert pid.output |> D.equal?(D.new("0.5"))
  end

  test "proportional control with measurement at setpoint" do
    pid = PID.new(kp: @one) |> PID.iterate(@one, @one)
    assert pid.output |> D.equal?(D.new("0"))
  end

  test "proportional control with measurement to zero and negative setpoint" do
    pid = PID.new(kp: @one) |> PID.iterate(@zero, @minus_one)
    assert pid.output |> D.equal?(@minus_one)
  end

  test "proportional control with measurement halfway and negative setpoint" do
    pid = PID.new(kp: @one) |> PID.iterate(D.new("-0.5"), @minus_one)
    assert pid.output |> D.equal?(D.new("-0.5"))
  end

  test "proportional control with measurement at setpoint and negative setpoint" do
    pid = PID.new(kp: @one) |> PID.iterate(@minus_one, @minus_one)
    assert pid.output |> D.equal?(D.new("0"))
  end

  test "derivative control converges" do
    setpoint = @one
    pid = PID.new(kp: D.new("0.08"), kd: D.new("0.1"))
    pid_output = Enum.reduce(0..100, D.new("0.0"), fn x, acc ->
      Process.sleep(10)
      pid = PID.iterate(pid, acc, setpoint)
      pid.output |> D.add(acc)
    end)
    assert D.round(pid_output) |> D.equal?(@one)
  end

  test "initial derivative term should be zero" do
    pid = PID.new(kd: D.new(1)) |> PID.iterate(@zero, @one)
    assert pid.output |> D.equal?(0)
  end

  test "integral control converges" do
    setpoint = @one
    pid = PID.new(kp: D.new("0.08"), ki: D.new("2.0"))
    pid_output = Enum.reduce(0..100, D.new("0.0"), fn x, acc ->
      Process.sleep(10)
      pid = PID.iterate(pid, acc, setpoint)
      pid.output |> D.add(acc)
    end)
    assert D.round(pid_output) |> D.equal?(@one)
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
