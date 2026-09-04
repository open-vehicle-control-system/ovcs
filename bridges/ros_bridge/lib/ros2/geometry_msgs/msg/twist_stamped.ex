defmodule Ros2.GeometryMsgs.Msg.TwistStamped do
  @moduledoc """
  ROS 2 `geometry_msgs/TwistStamped`: a `Header`, then a `Twist`.

  This is what Nav2 publishes. `nav2_util::TwistPublisher` reads
  `enable_stamped_cmd_vel` with a default of **true**, and
  `controller_server::publishVelocity` takes a `TwistStamped` — the
  doc comment in that header still claims unstamped is the default,
  and the code disagrees.

  The stamp is the reason to prefer it. A velocity command carries no
  indication of its own age otherwise, so a consumer cannot tell a
  fresh command from one a dead planner left behind — and
  `Cantastic.Emitter` will happily retransmit the stale one for ever.

  `Twist` opens with a `float64`, so it has to start 8-aligned. Nested
  after a `Header` — whose trailing `frame_id` string pads only to 4 —
  that is not automatic, which is why the padding is explicit below.
  Getting it wrong shifts every field and decodes to plausible
  nonsense rather than to an error.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Twist
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil, twist: %Twist{}

  def parse(body) when is_binary(body) do
    with {:ok, header, rest} <- Header.parse(body),
         rest <- skip_padding_to(body, rest, 8),
         {:ok, twist, rest} <- Twist.parse(rest) do
      {:ok, %__MODULE__{header: header, twist: twist}, rest}
    end
  end

  # How far into the body we are, so the padding is computed against
  # the body origin rather than against the start of this struct.
  defp skip_padding_to(body, rest, alignment) do
    consumed = byte_size(body) - byte_size(rest)
    padding = rem(alignment - rem(consumed, alignment), alignment)
    binary_part(rest, padding, byte_size(rest) - padding)
  end
end
