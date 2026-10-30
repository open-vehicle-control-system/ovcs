defmodule VisionApiWeb.MemoryStore do
  @moduledoc "A parameter store held in an Agent, so saved values do not outlive a test."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def load, do: Agent.get(__MODULE__, & &1)

  def write(changes) do
    Agent.update(__MODULE__, fn rows ->
      Enum.reduce(changes, rows, fn
        {id, :delete}, rows -> Map.delete(rows, id)
        {id, value}, rows -> Map.put(rows, id, value)
      end)
    end)
  end
end

defmodule VisionApiWeb.FailingStore do
  @moduledoc "A parameter store that cannot write."

  def load, do: %{}
  def write(_changes), do: {:error, "saved parameters unavailable"}
end
