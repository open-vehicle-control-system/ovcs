defmodule RosBridge.Publishers.PathPredictionTest do
  @moduledoc """
  The bicycle model's arc and the direction it is drawn in.
  """
  use ExUnit.Case, async: true

  alias RosBridge.Publishers.PathPrediction

  @wheelbase 0.3

  test "straight ahead, base_link moves along x" do
    pose = PathPrediction.pose_at(0.0, 1.0, 0.15)
    assert_in_delta pose.position.x, 1.0, 1.0e-9
    assert_in_delta pose.position.y, 0.0, 1.0e-9
  end

  test "a quarter turn left about the rear axle" do
    radius = 1.0
    pose = PathPrediction.pose_at(1 / radius, :math.pi() / 2 * radius, 0.0)
    assert_in_delta pose.position.x, radius, 1.0e-9
    assert_in_delta pose.position.y, radius, 1.0e-9
    assert_in_delta pose.orientation.z, :math.sin(:math.pi() / 4), 1.0e-9
  end

  test "base_link ahead of the rear axle swings out with the heading" do
    pose = PathPrediction.pose_at(1.0, :math.pi() / 2, 0.15)
    assert_in_delta pose.position.x, 1.0 - 0.15, 1.0e-9
    assert_in_delta pose.position.y, 1.0 + 0.15, 1.0e-9
  end

  test "steering left curves left" do
    assert PathPrediction.curvature(0.3, @wheelbase) > 0.0
  end

  test "the arc starts at base_link and runs the requested length behind in reverse" do
    poses = PathPrediction.arc(0.0, -2.5, 0.05, 0.15)
    assert length(poses) == 51
    assert_in_delta hd(poses).position.x, 0.0, 1.0e-9
    assert_in_delta List.last(poses).position.x, -2.5, 1.0e-9
  end

  test "moving decides the direction, the gear does at a standstill" do
    assert PathPrediction.direction(0.5, "reverse") == 1
    assert PathPrediction.direction(-0.5, "drive") == -1
    assert PathPrediction.direction(0.0, "reverse") == -1
    assert PathPrediction.direction(0.0, "drive") == 1
  end
end
