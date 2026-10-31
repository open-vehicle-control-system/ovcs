defmodule VisionCore.ComponentsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Components

  # A unit that gives up exits :shutdown; restarting it would spend the vision core's own budget.
  test "the stereo and detection units are not restarted once they give up" do
    for component <- [:detector, :stereo] do
      assert [%{restart: :transient}] = Components.start(component, [])
    end
  end
end
