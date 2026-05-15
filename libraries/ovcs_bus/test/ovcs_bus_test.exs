defmodule OvcsBusTest do
  use ExUnit.Case, async: false

  setup do
    # Under `mix test --no-start`, OvcsBus.Application hasn't registered
    # Phoenix.PubSub under name OvcsBus, and phoenix_pubsub's own OTP
    # app isn't up either. Make sure both are in place before each test.
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(OvcsBus) do
      start_supervised!({Phoenix.PubSub, name: OvcsBus})
    end

    :ok
  end

  test "broadcast delivers the message to every subscriber of the topic" do
    :ok = OvcsBus.subscribe("messages")

    message = %OvcsBus.Message{name: :ready_to_drive, value: true, source: __MODULE__}
    OvcsBus.broadcast("messages", message)

    assert_receive ^message
  end

  test "broadcast does not deliver to subscribers of other topics" do
    :ok = OvcsBus.subscribe("other-topic")

    OvcsBus.broadcast("messages", %OvcsBus.Message{name: :x, value: 1, source: __MODULE__})

    refute_receive _, 50
  end

  test "unsubscribe stops further delivery on that topic" do
    :ok = OvcsBus.subscribe("messages")
    :ok = OvcsBus.unsubscribe("messages")

    OvcsBus.broadcast("messages", %OvcsBus.Message{name: :x, value: 1, source: __MODULE__})

    refute_receive _, 50
  end
end
