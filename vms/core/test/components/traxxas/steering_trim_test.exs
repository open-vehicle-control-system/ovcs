defmodule VmsCore.Components.Traxxas.SteeringTrimTest do
  @moduledoc """
  The steering trim: added to every request before the clamp, read off
  the duty cycle a fake controller receives.
  """
  use ExUnit.Case, async: true
  alias Decimal, as: D
  alias VmsCore.Components.Traxxas.Steering

  defmodule FakeController do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call({:set_external_pwm, _id, _enabled, duty_cycle, _frequency}, _from, test_pid) do
      send(test_pid, {:duty_cycle, duty_cycle})
      {:reply, :ok, test_pid}
    end
  end

  defp steer(requested_steering, trim) do
    {:ok, controller} = FakeController.start_link(self())

    state = %{
      loop_timer: nil,
      controller: controller,
      external_pwm_id: 0,
      selected_control_level_source: nil,
      requested_steering_source: nil,
      requested_steering: D.new(requested_steering),
      steering: D.new(99),
      trim: D.new(trim)
    }

    {:noreply, _state} = Steering.handle_info(:loop, state)
    assert_receive {:duty_cycle, duty_cycle}
    duty_cycle
  end

  test "trim offsets a straight request" do
    assert D.eq?(steer("0", "0.04"), D.new("0.152"))
  end

  test "trim shifts the opposite lock too" do
    assert D.eq?(steer("-1", "0.04"), D.new("0.102"))
  end

  test "a trimmed request is clamped to the servo's range" do
    assert D.eq?(steer("1", "0.04"), D.new("0.20"))
  end

  test "the first tick sends the trimmed centre" do
    {:ok, controller} = FakeController.start_link(self())

    {:ok, state} =
      Steering.init(%{
        controller: controller,
        external_pwm_id: 0,
        selected_control_level_source: nil,
        trim: "0.04"
      })

    :timer.cancel(state.loop_timer)
    {:noreply, _state} = Steering.handle_info(:loop, state)
    assert_receive {:duty_cycle, duty_cycle}
    assert D.eq?(duty_cycle, D.new("0.152"))
  end

  test "no trim leaves the request untouched" do
    assert D.eq?(steer("0.5", "0"), D.new("0.175"))
  end
end
