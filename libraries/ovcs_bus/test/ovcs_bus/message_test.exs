defmodule OvcsBus.MessageTest do
  use ExUnit.Case, async: true

  test "relay_origin defaults to nil so locally-published messages are re-broadcast by relays" do
    message = %OvcsBus.Message{name: :speed, value: 42, source: __MODULE__}
    assert message.relay_origin == nil
  end

  test "relay_origin can be tagged so relays drop echoes of their own inbound traffic" do
    message = %OvcsBus.Message{
      name: :speed,
      value: 42,
      source: __MODULE__,
      relay_origin: :mqtt
    }

    assert message.relay_origin == :mqtt
  end
end
