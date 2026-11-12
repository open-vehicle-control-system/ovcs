defmodule VmsCore.Components.OVCS.SteeringTuningTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsControl.{InputFilter, PID}
  alias VmsCore.Components.OVCS.SteeringColumn

  defp state do
    %{
      kp: D.new("0.07"),
      ki: D.new("0.005"),
      kd: D.new("0.005"),
      pid: PID.new(kp: D.new("0.07"), ki: D.new("0.005"), kd: D.new("0.005")),
      input_deadband: D.new(0),
      input_alpha: D.new("0.2"),
      input_filter: InputFilter.new(deadband: D.new(0), alpha: D.new("0.2"))
    }
  end

  for raw <- [
        nil,
        false,
        %{},
        [],
        "",
        "bad",
        "0.2suffix",
        "NaN",
        "Infinity",
        "-Infinity",
        "1e99999999"
      ] do
    test "refuses invalid PID gain #{inspect(raw)} without losing active tuning" do
      state = state()

      assert {:reply, {:error, _}, ^state} =
               SteeringColumn.handle_call(
                 {:set_pid_parameter, "kp", unquote(Macro.escape(raw))},
                 nil,
                 state
               )
    end
  end

  for {parameter, raw} <- [
        {"alpha", "-0.1"},
        {"alpha", "1.1"},
        {"alpha", "NaN"},
        {"deadband", -1},
        {"deadband", "Infinity"}
      ] do
    test "refuses invalid filter #{parameter}=#{raw} without losing active tuning" do
      state = state()

      assert {:reply, {:error, _}, ^state} =
               SteeringColumn.handle_call(
                 {:set_filter_parameter, unquote(parameter), unquote(raw)},
                 nil,
                 state
               )
    end
  end

  for {raw, expected} <- [{" 0.25 ", "0.25"}, {0.25, "0.25"}, {1, "1"}, {"-0.25", "-0.25"}] do
    test "updates stored and running PID gain from #{inspect(raw)}" do
      assert {:reply, :ok, updated} =
               SteeringColumn.handle_call({:set_pid_parameter, "ki", unquote(raw)}, nil, state())

      expected = D.new(unquote(expected))
      assert D.equal?(updated.ki, expected)
      assert D.equal?(updated.pid.ki, expected)
    end
  end

  for {parameter, raw} <- [{"alpha", 0}, {"alpha", 1}, {"deadband", 0}, {"deadband", "0.02"}] do
    test "updates stored and running filter #{parameter}=#{raw}" do
      assert {:reply, :ok, updated} =
               SteeringColumn.handle_call(
                 {:set_filter_parameter, unquote(parameter), unquote(raw)},
                 nil,
                 state()
               )

      key = String.to_existing_atom(unquote(parameter))
      state_key = String.to_existing_atom("input_" <> unquote(parameter))
      assert D.equal?(Map.fetch!(updated, state_key), D.new(unquote(raw)))
      assert D.equal?(Map.fetch!(updated.input_filter, key), D.new(unquote(raw)))
    end
  end

  test "stores valid gains before automatic steering has created a PID" do
    state = %{state() | pid: nil, input_filter: nil}

    assert {:reply, :ok, updated} =
             SteeringColumn.handle_call({:set_pid_parameter, "kd", "0.1"}, nil, state)

    assert updated.pid == nil
    assert D.equal?(updated.kd, D.new("0.1"))

    assert {:reply, :ok, updated} =
             SteeringColumn.handle_call({:set_filter_parameter, "alpha", "0.3"}, nil, updated)

    assert updated.input_filter == nil
    assert D.equal?(updated.input_alpha, D.new("0.3"))
  end

  test "rejects missing or unknown dashboard tuning parameters" do
    for action <- ["set_pid_parameter", "set_filter_parameter"],
        parameters <- [%{}, %{"parameter" => "unknown", "value" => "1"}] do
      assert SteeringColumn.trigger_action(action, parameters) ==
               {:error, :invalid_tuning_parameter}
    end
  end

  test "the pure validator rejects unknown parameters" do
    assert SteeringColumn.Tuning.parse("unknown", "1") == {:error, :invalid_tuning_parameter}
  end
end
