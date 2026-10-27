defmodule OvcsBusGateway.EnvelopeTest do
  use ExUnit.Case, async: true

  alias OvcsBusGateway.Envelope

  defp encoded_value(value) do
    message = %OvcsBus.Message{name: :signal, value: value, source: VmsCore.Vehicle}

    "vms"
    |> Envelope.new(message, 0)
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.fetch!("value")
  end

  test "new/3 builds the envelope" do
    message = %OvcsBus.Message{
      name: :speed,
      value: Decimal.new("12.5"),
      source: VmsCore.Vehicle,
      unit: "km/h"
    }

    envelope = Envelope.new("vms", message, 1_700_000_000_000)

    assert Jason.decode!(Jason.encode!(envelope)) == %{
             "node" => "vms",
             "source" => "VmsCore.Vehicle",
             "name" => "speed",
             "value" => 12.5,
             "unit" => "km/h",
             "timestamp" => 1_700_000_000_000
           }
  end

  test "new/3 accepts a signal name that is not an atom" do
    for {name, expected} <- [{"speed", "speed"}, {{:wheel, 1}, "{:wheel, 1}"}] do
      message = %OvcsBus.Message{name: name, value: 1, source: VmsCore.Vehicle}
      assert Envelope.new("vms", message, 0).name == expected
    end
  end

  test "new/3 makes any unit JSON-safe" do
    for {unit, expected} <- [
          {nil, nil},
          {"km/h", "km/h"},
          {:rpm, "rpm"},
          {{:per, :s}, "{:per, :s}"},
          {<<0xFF>>, "<<255>>"}
        ] do
      message = %OvcsBus.Message{name: :speed, value: 1, source: VmsCore.Vehicle, unit: unit}
      envelope = Envelope.new("vms", message, 0)
      assert envelope.unit == expected
      assert {:ok, _json} = Jason.encode(envelope)
    end
  end

  test "key/1 is the node, source and name" do
    message = %OvcsBus.Message{name: :speed, value: 1, source: VmsCore.Vehicle}

    assert "vms" |> Envelope.new(message, 0) |> Envelope.key() ==
             {"vms", "VmsCore.Vehicle", "speed"}
  end

  test "encodes atoms as strings without the colon" do
    assert encoded_value(:parking) == "parking"
    assert encoded_value(true) == true
    assert encoded_value(nil) == nil
  end

  test "keeps numbers and binaries" do
    assert encoded_value(3) == 3
    assert encoded_value(1.5) == 1.5
    assert encoded_value("text") == "text"
  end

  test "encodes a decimal as an exact number" do
    message = %OvcsBus.Message{
      name: :soc,
      value: Decimal.new("0.1000000000000000055"),
      source: VmsCore.Vehicle
    }

    assert "vms" |> Envelope.new(message, 0) |> Jason.encode!() =~
             ~s("value":0.1000000000000000055)
  end

  test "encodes any term" do
    for value <- [{:a, 1}, %{a: 1}, [1, 2], self(), make_ref(), %URI{}, <<255, 254>>] do
      assert is_binary(encoded_value(value))
    end
  end

  test "encodes non-finite decimals as valid JSON strings" do
    for value <- ["NaN", "Infinity", "-Infinity"] do
      message = %OvcsBus.Message{name: :soc, value: Decimal.new(value), source: VmsCore.Vehicle}
      json = "vms" |> Envelope.new(message, 0) |> Jason.encode!()

      assert is_binary(Jason.decode!(json)["value"])
    end
  end
end
