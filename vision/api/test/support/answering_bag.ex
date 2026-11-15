defmodule VisionApiWeb.AnsweringBag do
  @moduledoc """
  Has the bag exporter of the unit `VisionApiWeb.TestDisks.start_unit/2`
  starts answer every call of its functions with one answer, as one
  that times out or fails would: `answer/1` has its runner hand the
  calls to this module.
  """
  @behaviour VisionCore.Exporter

  @impl VisionCore.Exporter
  def outputs(_options), do: []

  @impl VisionCore.Exporter
  def init(_options), do: {:ok, nil}

  @impl VisionCore.Exporter
  def handle_output(_output, _value, answer), do: {:ok, answer}

  @impl VisionCore.Exporter
  def handle_call(_request, _from, answer), do: {:reply, answer, answer}

  @doc "Has the bag exporter's runner answer every call with `answer`."
  @spec answer(term()) :: :ok
  def answer(answer) do
    {:ok, runner} = VisionCore.Exporters.fetch_runner("ros2_bag")
    :sys.replace_state(runner, &%{&1 | exporter: __MODULE__, exporter_state: answer})
    :ok
  end
end
