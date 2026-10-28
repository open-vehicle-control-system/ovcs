defmodule Ros2Zenoh do
  @moduledoc """
  ROS 2 messages over Zenoh, without ROS installed: CDR codecs for the
  standard message types (`Ros2Zenoh.<Package>.Msg.<Name>`) and the
  `rmw_zenoh` wire format (`Ros2Zenoh.RmwZenoh`), so plain Zenoh
  publishers and subscribers interoperate with ROS 2 nodes that run
  `rmw_zenoh`.

  The library holds no Zenoh session: callers publish and subscribe
  through their own client, such as `zenohex`.
  """
end
