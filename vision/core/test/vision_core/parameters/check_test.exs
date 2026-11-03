defmodule VisionCore.Parameters.CheckTest do
  use ExUnit.Case, async: true

  alias VisionCore.Parameters.Check

  @range %{kind: :range, min: 0, max: 78, step: nil}
  @huge 10 ** 400

  @specs [
    p1: %{type: :integer, range: {0, 78}},
    p2: %{type: :integer, range: {1, 79}, greater_than: :p1},
    uniqueness: %{type: :double, range: {1, 3}},
    paths: %{type: :integer, values: [3, 8], applies: :build}
  ]
  @defaults %{p1: 8, p2: 64, uniqueness: 1.5, paths: 8}

  describe "value/3" do
    test "takes a value of its type within its constraint, a double as a float" do
      assert Check.value(:integer, @range, 78) == {:ok, 78}
      assert Check.value(:integer, @range, 0) == {:ok, 0}
      assert Check.value(:double, @range, 2) == {:ok, 2.0}
      assert Check.value(:double, %{kind: :choices, values: [0.5, 1.0]}, 1) == {:ok, 1.0}
      assert Check.value(:bool, %{kind: :bool}, false) == {:ok, false}

      assert Check.value(:string, %{kind: :choices, values: ["jet", "gray"]}, "gray") ==
               {:ok, "gray"}

      assert Check.value(:integer, nil, 1_000) == {:ok, 1_000}
    end

    test "says what the value must be, and what it got" do
      assert Check.value(:integer, @range, "8") == {:error, ~s(must be an integer, got "8")}
      assert Check.value(:integer, @range, 8.0) == {:error, "must be an integer, got 8.0"}
      assert Check.value(:double, @range, {1, 2}) == {:error, "must be a number, got {1, 2}"}
      assert Check.value(:bool, %{kind: :bool}, 1) == {:error, "must be true or false, got 1"}
      assert Check.value(:string, nil, :jet) == {:error, "must be a string, got :jet"}
      assert Check.value(:integer, @range, 79) == {:error, "must be from 0 to 78, got 79"}
      assert Check.value(:double, @range, -0.5) == {:error, "must be from 0 to 78, got -0.5"}
      assert Check.value(:double, @range, 100) == {:error, "must be from 0 to 78, got 100"}

      assert Check.value(:integer, %{kind: :range, min: 10, max: 95, step: 5}, 52) ==
               {:error, "must be a multiple of 5 from 10, got 52"}

      assert Check.value(:string, %{kind: :choices, values: ["jet", "gray"]}, "hot") ==
               {:error, ~s(must be one of jet, gray, got "hot")}

      assert Check.value(:string, %{kind: :choices, values: [{:fixed, 2}, "auto", nil]}, "x") ==
               {:error, ~s(must be one of {:fixed, 2}, auto, nil, got "x")}
    end

    test "never raises: a number no double holds, a type it does not know, a zero step" do
      assert Check.value(:double, @range, @huge) == {:error, "must be from 0 to 78, got #{@huge}"}

      assert Check.value(:double, nil, -@huge) ==
               {:error, "must be a number a double can hold, got -#{@huge}"}

      assert Check.value(:float, nil, 1.0) == {:error, "must be of type :float, got 1.0"}
      assert Check.value(:integer, %{kind: :range, min: 0, max: 10, step: 0}, 5) == {:ok, 5}
    end
  end

  describe "order/2" do
    test "keeps a value above and below the settings it is ordered against" do
      assert Check.order(9, above: {:p1, 8}) == :ok
      assert Check.order(8, above: {:p1, 8}) == {:error, "must be above p1 (8), got 8"}
      assert Check.order(63, below: {:p2, 64}) == :ok
      assert Check.order(70, below: {:p2, 64}) == {:error, "must be below p2 (64), got 70"}

      assert Check.order(9, above: {"stereo.disparity.p1", 8}, below: {"stereo.x", 9}) ==
               {:error, "must be below stereo.x (9), got 9"}
    end

    test "passes a setting whose value is unknown" do
      assert Check.order(1, above: {:p1, nil}) == :ok
    end
  end

  test "constraint/1 is the registry's constraint of a spec" do
    assert Check.constraint(%{type: :bool}) == %{kind: :bool}

    assert Check.constraint(%{type: :integer, values: [3, 5]}) == %{
             kind: :choices,
             values: [3, 5]
           }

    assert Check.constraint(%{type: :integer, range: {1, 16}, step: 1}) ==
             %{kind: :range, min: 1, max: 16, step: 1}

    assert Check.constraint(%{type: :double, range: {0, 8}}) ==
             %{kind: :range, min: 0, max: 8, step: nil}

    assert Check.constraint(%{type: :integer}) == nil
  end

  describe "init_settings/3" do
    test "the defaults, with the options over them, a double as a float" do
      assert Check.init_settings(@specs, @defaults, []) == {:ok, @defaults}

      assert Check.init_settings(@specs, @defaults, p2: 79, uniqueness: 2, paths: 3) ==
               {:ok, %{p1: 8, p2: 79, uniqueness: 2.0, paths: 3}}
    end

    test "refuses an option it does not declare, any option without settings, and a non-keyword list" do
      assert Check.init_settings(@specs, @defaults, p3: 1) == {:error, "p3 is not a setting"}
      assert Check.init_settings([], %{}, []) == {:ok, %{}}
      assert Check.init_settings([], %{}, size: 3) == {:error, "size is not a setting"}

      assert Check.init_settings(@specs, @defaults, [1, 2]) ==
               {:error, "options must be a keyword list, got [1, 2]"}
    end

    test "refuses a value its spec does not accept, naming the setting" do
      assert Check.init_settings(@specs, @defaults, p1: 79) ==
               {:error, "p1 must be from 0 to 78, got 79"}

      assert Check.init_settings(@specs, @defaults, paths: 4) ==
               {:error, "paths must be one of 3, 8, got 4"}

      assert Check.init_settings(@specs, @defaults, uniqueness: nil) ==
               {:error, "uniqueness must be a number, got nil"}

      assert Check.init_settings(@specs, @defaults, uniqueness: @huge) ==
               {:error, "uniqueness must be from 1 to 3, got #{@huge}"}
    end

    test "refuses settings out of order, from the side of the option given" do
      assert Check.init_settings(@specs, @defaults, p1: 70) ==
               {:error, "p1 must be below p2 (64), got 70"}

      assert Check.init_settings(@specs, @defaults, p2: 5) ==
               {:error, "p2 must be above p1 (8), got 5"}

      assert Check.init_settings(@specs, @defaults, p1: 0, p2: 1) ==
               {:ok, %{@defaults | p1: 0, p2: 1}}
    end
  end

  describe "live_setting/2" do
    test "passes a live setting, and names a key it does not declare or fixes in the build" do
      assert Check.live_setting(@specs, :p1) == :ok
      assert Check.live_setting(@specs, :p3) == {:error, "p3 is not a setting"}
      assert Check.live_setting(@specs, "p1") == {:error, ~s("p1" is not a setting)}
      assert Check.live_setting(@specs, nil) == {:error, "nil is not a setting"}
      assert Check.live_setting(@specs, {:p, 1}) == {:error, "{:p, 1} is not a setting"}

      assert Check.live_setting(@specs, :paths) ==
               {:error, "paths is fixed when the stage starts"}
    end
  end

  describe "change_setting/4" do
    test "takes a live setting's new value, a double as a float" do
      assert Check.change_setting(@specs, @defaults, :p1, 63) == {:ok, 63}
      assert Check.change_setting(@specs, @defaults, :uniqueness, 3) == {:ok, 3.0}
    end

    test "refuses a key it does not declare, or fixes in the build" do
      assert Check.change_setting(@specs, @defaults, :p3, 1) == {:error, "p3 is not a setting"}

      assert Check.change_setting(@specs, @defaults, "p1", 1) ==
               {:error, ~s("p1" is not a setting)}

      assert Check.change_setting(@specs, @defaults, :paths, 3) ==
               {:error, "paths is fixed when the stage starts"}
    end

    test "refuses a value its spec does not accept, and one out of order" do
      assert Check.change_setting(@specs, @defaults, :p1, {1, 2}) ==
               {:error, "p1 must be an integer, got {1, 2}"}

      assert Check.change_setting(@specs, @defaults, :p1, nil) ==
               {:error, "p1 must be an integer, got nil"}

      assert Check.change_setting(@specs, @defaults, :uniqueness, @huge) ==
               {:error, "uniqueness must be from 1 to 3, got #{@huge}"}

      assert Check.change_setting(@specs, @defaults, :p2, 80) ==
               {:error, "p2 must be from 1 to 79, got 80"}

      assert Check.change_setting(@specs, @defaults, :p2, 8) ==
               {:error, "p2 must be above p1 (8), got 8"}

      assert Check.change_setting(@specs, @defaults, :p1, 64) ==
               {:error, "p1 must be below p2 (64), got 64"}
    end
  end
end
