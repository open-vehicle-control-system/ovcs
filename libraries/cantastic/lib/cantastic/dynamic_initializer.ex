defmodule Cantastic.DynamicInitializer do
  use GenServer

  alias Cantastic.Interface

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    start_interfaces()
    {:ok, %{}}
  end

  defp start_interfaces() do
    Interface.configure_children()
    |> Enum.each(fn(child_spec) ->
      {:ok, _child} = DynamicSupervisor.start_child(Cantastic.DynamicSupervisor, child_spec)
    end)
  end

end
