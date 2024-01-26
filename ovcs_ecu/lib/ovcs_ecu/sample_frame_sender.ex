defmodule OvcsEcu.SampleFrameSender do
  alias Cantastic.{Frame}

  def send_test_frame() do
    Frame.send("drive", "A05", "AABBFF")
    Frame.send("drive", "A05", "FFFFFFFFFFFFFFFF")
  end
end
