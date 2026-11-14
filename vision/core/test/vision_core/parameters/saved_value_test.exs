defmodule VisionCore.Parameters.SavedValueTest do
  use ExUnit.Case, async: true

  alias VisionCore.Parameters.SavedValue

  test "takes a parameter's id and its value as JSON" do
    changeset = SavedValue.changeset(%SavedValue{}, %{parameter_id: "a.b.c", value: "10"})

    assert changeset.valid?
    assert changeset.changes == %{parameter_id: "a.b.c", value: "10"}
  end

  test "refuses a value without its parameter's id or its JSON" do
    changeset = SavedValue.changeset(%SavedValue{}, %{parameter_id: nil, value: nil})

    refute changeset.valid?
    assert {_message, [validation: :required]} = changeset.errors[:parameter_id]
    assert {_message, [validation: :required]} = changeset.errors[:value]
  end
end
