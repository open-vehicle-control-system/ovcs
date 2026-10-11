defmodule VmsCore.MetricsTest do
  @moduledoc """
  The metrics store: the last value and unit per source and name.

  Driven through the callbacks directly, so the tests stay pure and
  need no process subscribed to the bus.
  """
  use ExUnit.Case, async: true

  alias OvcsBus.Message
  alias VmsCore.Metrics

  @empty_state %{sources: %{}}

  describe "handle_info/2" do
    test "records the first message from a source under that source + name" do
      message = %Message{name: :speed, value: 42, source: SomeSensor}

      {:noreply, state} = Metrics.handle_info(message, @empty_state)

      assert state.sources == %{SomeSensor => %{speed: 42}}
    end

    test "accumulates multiple names under the same source" do
      state = @empty_state
      {:noreply, state} = Metrics.handle_info(%Message{name: :speed, value: 42, source: S}, state)
      {:noreply, state} = Metrics.handle_info(%Message{name: :rpm, value: 900, source: S}, state)

      assert state.sources == %{S => %{speed: 42, rpm: 900}}
    end

    test "the most recent value for a (source, name) pair overwrites earlier ones" do
      state = @empty_state
      {:noreply, state} = Metrics.handle_info(%Message{name: :speed, value: 10, source: S}, state)
      {:noreply, state} = Metrics.handle_info(%Message{name: :speed, value: 20, source: S}, state)

      assert state.sources == %{S => %{speed: 20}}
    end

    test "keeps sources isolated from each other" do
      state = @empty_state

      {:noreply, state} =
        Metrics.handle_info(%Message{name: :voltage, value: 400, source: BmsA}, state)

      {:noreply, state} =
        Metrics.handle_info(%Message{name: :voltage, value: 12, source: BmsB}, state)

      assert state.sources == %{BmsA => %{voltage: 400}, BmsB => %{voltage: 12}}
    end
  end

  describe "units" do
    test "the publisher's unit is kept per source and name" do
      state = @empty_state

      {:noreply, state} =
        Metrics.handle_info(%Message{name: :voltage, value: 15.7, unit: "V", source: Vesc}, state)

      {:noreply, state} =
        Metrics.handle_info(%Message{name: :gear, value: :drive, source: Vesc}, state)

      assert state.units == %{Vesc => %{voltage: "V"}}
      assert state.sources == %{Vesc => %{voltage: 15.7, gear: :drive}}
    end

    test "a message without a unit leaves the last unit in place" do
      # A dead frame publishes nil values; the unit of the metric does
      # not change because its value is unknown.
      state = %{sources: %{}, units: %{Vesc => %{voltage: "V"}}}

      {:noreply, state} =
        Metrics.handle_info(%Message{name: :voltage, value: nil, source: Vesc}, state)

      assert state.units == %{Vesc => %{voltage: "V"}}
    end
  end

  describe "handle_call({:metrics, source})" do
    setup do
      state = %{
        sources: %{
          BmsA => %{voltage: 400, temperature: 25},
          BmsB => %{voltage: 12}
        }
      }

      %{state: state}
    end

    test "returns every source when the filter is nil", %{state: state} do
      {:reply, {:ok, all}, ^state} = Metrics.handle_call({:metrics, nil}, :from, state)
      assert all == state.sources
    end

    test "returns only the requested source", %{state: state} do
      {:reply, {:ok, metrics}, ^state} = Metrics.handle_call({:metrics, BmsA}, :from, state)
      assert metrics == %{voltage: 400, temperature: 25}
    end

    test "returns an empty map when the source has no recorded metrics", %{state: state} do
      {:reply, {:ok, metrics}, ^state} = Metrics.handle_call({:metrics, Unknown}, :from, state)
      assert metrics == %{}
    end
  end
end
