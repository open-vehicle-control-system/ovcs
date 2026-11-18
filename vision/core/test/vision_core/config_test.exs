defmodule VisionCore.ConfigTest do
  use ExUnit.Case, async: true

  test "joins the site networks unless the composer sets another Wi-Fi mode" do
    assert %VisionCore.Config{}.wifi == :join
  end
end
