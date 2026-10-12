defmodule RosBridge.Consumers.Joy.ProfileTest do
  use ExUnit.Case, async: true

  alias RosBridge.Consumers.Joy.Profile

  @wheel_yaml """
  device: G923 Racing Wheel
  steering:
    - axis: 0
      gain: -5.0
  throttle:
    - pedal: 1
  brake:
    - pedal: 2
  gears:
    forward: [12, 13, 14, 15, 16, 17]
    backward: [11]
  """

  defp wheel, do: Profile.parse!("g923", YamlElixir.read_from_string!(@wheel_yaml))

  defp command(profile, axes, released \\ MapSet.new()) do
    {steering, throttle, _} = Profile.command(profile, axes, released)
    {steering, throttle}
  end

  describe "parse!/2" do
    test "reads the device and each output's terms" do
      assert %Profile{
               name: "g923",
               device: "G923 Racing Wheel",
               steering: [{:axis, 0, -5.0}],
               throttle: [{:pedal, 1, 1.0}],
               brake: [{:pedal, 2, 1.0}],
               gears: %{
                 forward: [{:button, 12}, {:button, 13}, {:button, 14} | _],
                 backward: [{:button, 11}]
               }
             } = wheel()
    end

    test "rejects a device that is not a regular expression" do
      assert_raise ArgumentError, ~r/device/, fn -> Profile.parse!("bad", %{"device" => "("}) end
    end

    test "rejects a term that names no axis" do
      assert_raise ArgumentError, ~r/bad term/, fn ->
        Profile.parse!("bad", %{"steering" => [%{"gain" => 2.0}]})
      end
    end
  end

  test "load_dir!/1 reads every profile in a directory, named after its file" do
    profiles_directory =
      Path.join(System.tmp_dir!(), "joy_profiles_#{System.unique_integer([:positive])}")

    File.mkdir_p!(profiles_directory)
    File.write!(Path.join(profiles_directory, "g923.yml"), @wheel_yaml)
    File.write!(Path.join(profiles_directory, "gamepad.yml"), "throttle:\n  - axis: 1\n")

    assert profiles_directory |> Profile.load_dir!() |> Enum.map(&Profile.topic/1) |> Enum.sort() ==
             ["joy/g923", "joy/gamepad"]
  end

  describe "direction/3" do
    defp buttons(held), do: for(i <- 0..22, do: if(i in held, do: 1, else: 0))

    defp xbox do
      Profile.parse!("xbox", %{
        "gears" => %{"forward" => [%{"trigger" => 5}], "backward" => [%{"trigger" => 2}]}
      })
    end

    test "reads a gear lever's held button" do
      assert Profile.direction(wheel(), [], buttons([14])) == :forward
      assert Profile.direction(wheel(), [], buttons([11])) == :backward
      assert Profile.direction(wheel(), [], buttons([])) == :neutral
      assert Profile.direction(wheel(), [], []) == :neutral
    end

    test "reads a held trigger, resting at 1" do
      assert Profile.direction(xbox(), [0.0, 0.0, 1.0, 0.0, 0.0, -1.0], []) == :forward
      assert Profile.direction(xbox(), [0.0, 0.0, -0.8, 0.0, 0.0, 1.0], []) == :backward
      assert Profile.direction(xbox(), [0.0, 0.0, 1.0, 0.0, 0.0, 0.2], []) == :neutral
    end

    test "a trigger joy_linux has not reported yet is not held" do
      assert Profile.direction(xbox(), [0.0, 0.0, 0.0, 0.0, 0.0, 0.0], []) == :neutral
    end

    test "both directions held is neutral" do
      assert Profile.direction(xbox(), [0.0, 0.0, -1.0, 0.0, 0.0, -1.0], []) == :neutral
    end

    test "is nil without gears" do
      assert Profile.direction(Profile.parse!("stick", %{}), [], buttons([11])) == nil
    end

    test "rejects a control that is not a button or a trigger" do
      assert_raise ArgumentError, ~r/gears: bad forward/, fn ->
        Profile.parse!("bad", %{"gears" => %{"forward" => ["first"]}})
      end
    end
  end

  test "the framework ships the Xbox controller, the F310 and the G923" do
    assert Profile.framework_dir()
           |> Profile.load_dir!()
           |> Enum.map(&{&1.name, &1.device})
           |> Enum.sort() == [
             {"f310", "(?i)gamepad f310"},
             {"g923", "G923 Racing Wheel"},
             {"xbox", "(?i)x-?box.*(pad|controller)"}
           ]
  end

  test "each shipped controller's kernel name picks its profile alone" do
    profiles = Profile.load_dir!(Profile.framework_dir())

    for {kernel_name, profile} <- [
          {"Logitech Gamepad F310", "f310"},
          {"Microsoft X-Box 360 pad", "xbox"},
          {"Logitech G923 Racing Wheel for PlayStation and PC", "g923"}
        ] do
      assert for(p <- profiles, Regex.match?(Regex.compile!(p.device), kernel_name), do: p.name) ==
               [profile]
    end
  end

  defp xbox_profile, do: Profile.framework_dir() |> Path.join("xbox.yml") |> Profile.load!()

  describe "command/3 with the Xbox controller" do
    test "centre is zero on both outputs" do
      assert command(xbox_profile(), [0.0, 0.0]) == {0.0, 0.0}
    end

    # The right stick: x (3) steers, y (4) drives.
    test "steering is inverted, throttle is not" do
      assert command(xbox_profile(), [0.9, 0.9, 0.0, 0.5, -0.25, 0.0]) == {-0.5, -0.25}
    end

    test "an over-range axis clamps rather than wrapping on the wire" do
      assert command(xbox_profile(), [0.0, 0.0, 0.0, 2.0, -5.0, 0.0]) == {-1.0, -1.0}
    end

    test "a missing, nil or non-numeric axis reads as centre" do
      assert command(xbox_profile(), []) == {0.0, 0.0}
      assert command(xbox_profile(), nil) == {0.0, 0.0}
      assert command(xbox_profile(), [:up, nil]) == {0.0, 0.0}
    end

    test "an integer axis is accepted" do
      assert command(xbox_profile(), [0, 0, 0, 1, 0, 0]) == {-1.0, 0.0}
    end
  end

  describe "command/3 with the wheel" do
    test "the gain reaches full lock early and clamps past it" do
      assert {-0.5, _} = command(wheel(), [0.1, -1.0, -1.0])
      assert {1.0, _} = command(wheel(), [-0.5, -1.0, -1.0])
    end

    test "the accelerator drives, the brake brakes" do
      released = MapSet.new([1, 2])
      assert {_, 1.0} = command(wheel(), [0.0, 1.0, -1.0], released)
      assert {_, -0.5} = command(wheel(), [0.0, -1.0, 0.0], released)
    end

    test "the brake wins over the accelerator" do
      released = MapSet.new([1, 2])
      assert {_, -0.5} = command(wheel(), [0.0, 1.0, 0.0], released)
    end

    test "a brake at rest leaves the accelerator alone" do
      released = MapSet.new([1, 2])
      assert {_, 1.0} = command(wheel(), [0.0, 1.0, -0.99], released)
    end

    test "a pedal reads as released until it has been seen released" do
      {_, throttle, released} = Profile.command(wheel(), [0.0, 0.0, 0.0])
      assert throttle == 0.0
      {_, _, released} = Profile.command(wheel(), [0.0, -1.0, 0.0], released)
      assert {_, 0.5} = command(wheel(), [0.0, 0.0, 0.0], released)
    end
  end
end
