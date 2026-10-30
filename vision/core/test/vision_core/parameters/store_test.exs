defmodule VisionCore.Parameters.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Parameters.{SavedValue, Store}
  alias VisionCore.Repo

  setup do
    Repo.delete_all(SavedValue)
    :ok
  end

  test "an empty database loads as no saved values" do
    assert Store.load() == %{}
  end

  test "writes values and loads them back with their types" do
    values = %{
      "stereo.match.p1" => 10,
      "stereo.temporal.alpha" => 0.5,
      "stereo.alignment.correction" => false,
      "stereo.cameras.rotation" => 180
    }

    :ok = Store.write(values)
    assert Store.load() == values
  end

  test "a second write replaces a value and :delete removes one" do
    :ok = Store.write(%{"a.b.c" => 1, "a.b.d" => 2})
    :ok = Store.write(%{"a.b.c" => 3, "a.b.d" => :delete})
    assert Store.load() == %{"a.b.c" => 3}
  end

  test "a row that is not valid JSON is skipped and logged" do
    Repo.insert!(%SavedValue{parameter_id: "a.b.c", value: "{not json"})
    {values, log} = with_log(fn -> Store.load() end)
    assert values == %{}
    assert log =~ "a.b.c"
  end
end
