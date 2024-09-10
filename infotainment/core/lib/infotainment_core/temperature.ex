defmodule InfotainmentCore.Temperature do
  use GenServer
  alias Decimal, as: D

  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, %{temperature: @zero}}
  end

  @impl true
  def handle_call(:temperature, _from, state) do
    {content, 0} = System.cmd("cat", ["/sys/class/thermal/thermal_zone0/temp"])
    {temperature_1000, _} = Integer.parse(content)
    state = %{state | temperature: temperature_1000/1000.0}
    {:reply, {:ok, state}, state}
  end

  def temperature do
    GenServer.call(__MODULE__, :temperature)
  end
end
