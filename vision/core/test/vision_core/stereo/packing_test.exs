defmodule VisionCore.Stereo.PackingTest do
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers, only: [context: 3, members: 2]

  alias VisionCore.Stereo.{Pipeline, Segment}

  test "packed transfer refuses a width that is not a multiple of 4" do
    context = context(:identity, 730, 108)
    members = members(Pipeline.default_stages(), context)

    assert {:error, message} = Segment.entry_specs(members, context, packed: true)
    assert message =~ "multiple of 4"
  end
end
