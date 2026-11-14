defmodule VisionCore.StageTimesTest do
  use ExUnit.Case, async: true

  alias VisionCore.StageTimes

  describe "summary/1" do
    test "gives each stage's mean time, and their sum as the total" do
      times =
        StageTimes.new()
        |> StageTimes.add(:input, 1.0)
        |> StageTimes.add(:input, 3.0)
        |> StageTimes.add(:inference, 10.0)

      assert StageTimes.summary(times) == %{
               total_ms: 12.0,
               stages: %{input: 2.0, inference: 10.0},
               segments: []
             }
    end

    test "gives a stage without a time nil, and leaves it out of the total" do
      times = StageTimes.new([:input, :inference]) |> StageTimes.add(:input, 4.0)

      assert StageTimes.summary(times) == %{
               total_ms: 4.0,
               stages: %{input: 4.0, inference: nil},
               segments: []
             }
    end

    test "has no total without any time" do
      assert StageTimes.summary(StageTimes.new([:input])) == %{
               total_ms: nil,
               stages: %{input: nil},
               segments: []
             }

      assert StageTimes.summary(StageTimes.new()) == StageTimes.none()
    end

    test "gives a run timed as one its one time, as a segment, and none to its members" do
      times =
        StageTimes.new()
        |> StageTimes.add(:"rectification+disparity+depth", 20.0)
        |> StageTimes.add(:"rectification+disparity+depth", 30.0)
        |> StageTimes.add(:frame_tag, 1.0)

      assert StageTimes.summary(times) == %{
               total_ms: 26.0,
               stages: %{frame_tag: 1.0},
               segments: [%{stages: [:rectification, :disparity, :depth], ms: 25.0}]
             }
    end

    test "counts a run whose members are timed too once in the total, and lists no segment" do
      times =
        StageTimes.new()
        |> StageTimes.add(:"rectification+disparity", 12.0)
        |> StageTimes.add(:rectification, 4.0)
        |> StageTimes.add(:disparity, 7.0)

      assert StageTimes.summary(times) == %{
               total_ms: 12.0,
               stages: %{rectification: 4.0, disparity: 7.0},
               segments: []
             }
    end
  end

  describe "reset/1" do
    test "starts every stage over, keeping the stages" do
      times =
        StageTimes.new([:input]) |> StageTimes.add(:input, 4.0) |> StageTimes.add(:late, 1.0)

      assert StageTimes.reset(times) == StageTimes.new([:input, :late])
    end
  end
end
