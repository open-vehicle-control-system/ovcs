defmodule OvcsBus.Mqtt.Relay.HandlerTest do
  use ExUnit.Case, async: false

  alias OvcsBus.Mqtt.Relay.Handler

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(OvcsBus) do
      start_supervised!({Phoenix.PubSub, name: OvcsBus})
    end

    :ok = OvcsBus.subscribe("messages")
    :ok
  end

  test "a valid OvcsBus.Message payload is tagged :mqtt and re-broadcast locally" do
    original = %OvcsBus.Message{name: :speed, value: 42, source: __MODULE__}
    payload = :erlang.term_to_binary(original)

    {:ok, _} = Handler.handle_message(["ovcs", "speed"], payload, %{bus_topic: "messages"})

    assert_receive %OvcsBus.Message{
      name: :speed,
      value: 42,
      source: __MODULE__,
      relay_origin: :mqtt
    }
  end

  test "a malformed binary payload is dropped silently without broadcasting" do
    {:ok, _} =
      Handler.handle_message(["ovcs", "speed"], "definitely not a term", %{bus_topic: "messages"})

    refute_receive %OvcsBus.Message{}, 50
  end

  test "a valid term that isn't an OvcsBus.Message is dropped silently" do
    # e.g. a producer on the broker publishing an unrelated erlang term
    payload = :erlang.term_to_binary({:not_a_message, 123})

    {:ok, _} = Handler.handle_message(["ovcs", "x"], payload, %{bus_topic: "messages"})

    refute_receive _, 50
  end

  test "payload is broadcast to the configured bus topic, not a hardcoded one" do
    :ok = OvcsBus.subscribe("custom-topic")

    payload =
      :erlang.term_to_binary(%OvcsBus.Message{
        name: :something,
        value: 1,
        source: __MODULE__
      })

    {:ok, _} = Handler.handle_message(["t"], payload, %{bus_topic: "custom-topic"})

    assert_receive %OvcsBus.Message{name: :something, relay_origin: :mqtt}
  end
end
