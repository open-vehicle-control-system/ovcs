defmodule OvcsBus.MessageTest do
  use ExUnit.Case, async: true

  test "unit defaults to nil for states, flags and normalised requests" do
    message = %OvcsBus.Message{name: :ready_to_drive, value: true, source: __MODULE__}
    assert message.unit == nil
  end

  test "name and source are enforced keys" do
    assert_raise ArgumentError, fn ->
      Code.eval_string("%OvcsBus.Message{value: 42}")
    end
  end
end
