defmodule VmsCore.MetricsTest do
  use ExUnit.Case, async: true

  alias OvcsBus.Message
  alias VmsCore.Metrics

  # The GenServer's init/1 calls Bus.subscribe which needs Phoenix.PubSub
  # running; we exercise the callbacks directly instead so these tests
  # stay pure and don't need the app booted.
  @empty_state %{sources: %{}}

  describe "handle_info/2" do
    test "records the first message from a source under that source + name" do
      msg = %Message{name: :speed, value: 42, source: SomeSensor}

      {:noreply, state} = Metrics.handle_info(msg, @empty_state)

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
      {:reply, {:ok, result}, ^state} = Metrics.handle_call({:metrics, BmsA}, :from, state)
      assert result == %{voltage: 400, temperature: 25}
    end

    test "returns an empty map when the source has no recorded metrics", %{state: state} do
      {:reply, {:ok, result}, ^state} = Metrics.handle_call({:metrics, Unknown}, :from, state)
      assert result == %{}
    end
  end
end
