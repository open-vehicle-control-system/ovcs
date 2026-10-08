defmodule RosBridge.Consumers.Joy.ProfileTest do
  use ExUnit.Case, async: true

  alias RosBridge.Consumers.Joy.Profile

  @wheel_yaml """
  topic: joy_wheel
  steering:
    - axis: 0
      gain: -5.0
  throttle:
    - pedal: 1
    - pedal: 2
      gain: -1
  """

  defp wheel, do: Profile.parse!("g923", YamlElixir.read_from_string!(@wheel_yaml))

  defp command(profile, axes, released \\ MapSet.new()) do
    {steering, throttle, _} = Profile.command(profile, axes, released)
    {steering, throttle}
  end

  describe "parse!/2" do
    test "reads the topic and each output's terms" do
      assert %Profile{
               name: "g923",
               topic: "joy_wheel",
               steering: [{:axis, 0, -5.0}],
               throttle: [{:pedal, 1, 1.0}, {:pedal, 2, -1.0}]
             } = wheel()
    end

    test "rejects a term that names no axis" do
      assert_raise ArgumentError, ~r/bad term/, fn ->
        Profile.parse!("bad", %{"steering" => [%{"gain" => 2.0}]})
      end
    end
  end

  test "load_dir!/1 reads every profile in a directory, named after its file" do
    dir = Path.join(System.tmp_dir!(), "joy_profiles_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "g923.yml"), @wheel_yaml)
    File.write!(Path.join(dir, "gamepad.yml"), "topic: joy\nthrottle:\n  - axis: 1\n")

    assert dir |> Profile.load_dir!() |> Enum.map(&{&1.name, &1.topic}) |> Enum.sort() ==
             [{"g923", "joy_wheel"}, {"gamepad", "joy"}]
  end

  describe "command/3 with the gamepad" do
    test "centre is zero on both outputs" do
      assert command(Profile.gamepad(), [0.0, 0.0]) == {0.0, 0.0}
    end

    test "steering is inverted, throttle is not" do
      assert command(Profile.gamepad(), [0.5, -0.25]) == {-0.5, -0.25}
    end

    test "an over-range axis clamps rather than wrapping on the wire" do
      assert command(Profile.gamepad(), [2.0, -5.0]) == {-1.0, -1.0}
    end

    test "a missing, nil or non-numeric axis reads as centre" do
      assert command(Profile.gamepad(), []) == {0.0, 0.0}
      assert command(Profile.gamepad(), nil) == {0.0, 0.0}
      assert command(Profile.gamepad(), [:up, nil]) == {0.0, 0.0}
    end

    test "an integer axis is accepted" do
      assert command(Profile.gamepad(), [1, 0]) == {-1.0, 0.0}
    end
  end

  describe "command/3 with the wheel" do
    test "the gain reaches full lock early and clamps past it" do
      assert {-0.5, _} = command(wheel(), [0.1, -1.0, -1.0])
      assert {1.0, _} = command(wheel(), [-0.5, -1.0, -1.0])
    end

    test "the throttle is the accelerator minus the brake" do
      released = MapSet.new([1, 2])
      assert {_, 1.0} = command(wheel(), [0.0, 1.0, -1.0], released)
      assert {_, -0.5} = command(wheel(), [0.0, 0.0, 1.0], released)
    end

    test "a pedal reads as released until it has been seen released" do
      {_, throttle, released} = Profile.command(wheel(), [0.0, 0.0, 0.0])
      assert throttle == 0.0
      {_, _, released} = Profile.command(wheel(), [0.0, -1.0, 0.0], released)
      assert {_, 0.5} = command(wheel(), [0.0, 0.0, 0.0], released)
    end
  end
end
