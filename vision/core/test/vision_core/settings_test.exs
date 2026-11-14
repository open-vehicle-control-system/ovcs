defmodule VisionCore.SettingsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Settings

  @specs [
    every_n: %{type: :integer, range: {1, 1000}, default: 1, description: "Images per run"},
    min_score: %{type: :double, range: {0, 1}, default: 0.4, description: "Lowest score"}
  ]

  describe "init!/2" do
    test "takes each setting from the options, its default without, a double as a float" do
      assert Settings.init!(@specs, min_score: 1, name: :road) == %{every_n: 1, min_score: 1.0}
    end

    test "refuses a value outside a setting's type or range, naming the option" do
      for {option, refused} <- [
            {[every_n: 0], "its :every_n must be from 1 to 1000, got 0"},
            {[every_n: 1.5], "its :every_n must be an integer, got 1.5"},
            {[min_score: "0.4"], "its :min_score must be a number, got \"0.4\""}
          ] do
        assert_raise ArgumentError, refused, fn -> Settings.init!(@specs, option) end
      end
    end
  end

  describe "put/4" do
    test "changes one setting, checked as at start, and leaves the rest of the map alone" do
      settings = %{every_n: 1, min_score: 0.4, name: :road}

      assert Settings.put(@specs, settings, :every_n, 3) ==
               {:ok, %{every_n: 3, min_score: 0.4, name: :road}}

      assert Settings.put(@specs, settings, :min_score, 2) ==
               {:error, "min_score must be from 0 to 1, got 2"}

      assert Settings.put(@specs, settings, :name, :other) == {:error, "name is not a setting"}
    end
  end

  test "values/2 are the settings by name, as a parameter group reads them" do
    assert Settings.values(@specs, %{every_n: 2, min_score: 0.5, name: :road}) ==
             %{"every_n" => 2, "min_score" => 0.5}
  end

  test "parameters/4 declare the settings named, live, with their start value as default" do
    test = self()
    set = fn key, value -> send(test, {:set, key, value}) && :ok end

    assert [parameter] = Settings.parameters(@specs, [:min_score], %{min_score: 0.5}, set)

    assert %{
             name: "min_score",
             type: :double,
             constraint: %{kind: :range, min: 0, max: 1},
             default: 0.5,
             description: "Lowest score"
           } = parameter

    refute Map.has_key?(parameter, :get)
    refute Map.has_key?(parameter, :applies)
    assert parameter.set.(0.7) == :ok
    assert_received {:set, :min_score, 0.7}
  end
end
