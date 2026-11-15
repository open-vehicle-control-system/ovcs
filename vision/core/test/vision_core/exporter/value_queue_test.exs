defmodule VisionCore.Exporter.ValueQueueTest do
  use ExUnit.Case, async: true

  alias VisionCore.Exporter.ValueQueue

  defp pop_all(queue, values \\ []) do
    case ValueQueue.pop(queue) do
      {:ok, value, queue} -> pop_all(queue, [value | values])
      :empty -> Enum.reverse(values)
    end
  end

  test "hands its values back in the order they came" do
    queue = Enum.reduce(1..3, ValueQueue.new(3), &ValueQueue.push(&2, &1))

    assert pop_all(queue) == [1, 2, 3]
    assert ValueQueue.dropped(queue) == 0
  end

  test "drops its oldest value for each one past its limit, and counts it" do
    queue = Enum.reduce(1..5, ValueQueue.new(3), &ValueQueue.push(&2, &1))

    assert pop_all(queue) == [3, 4, 5]
    assert ValueQueue.dropped(queue) == 2
  end

  test "takes values again once popped below its limit, dropping none" do
    queue = Enum.reduce(1..2, ValueQueue.new(2), &ValueQueue.push(&2, &1))
    {:ok, 1, queue} = ValueQueue.pop(queue)

    queue = ValueQueue.push(queue, 3)

    assert pop_all(queue) == [2, 3]
    assert ValueQueue.dropped(queue) == 0
  end

  test "is empty when new" do
    assert ValueQueue.pop(ValueQueue.new(1)) == :empty
  end
end
