defmodule VmsCore.BreakingSystem do
  use GenServer
  alias VmsCore.Controllers.FrontController
  alias VmsCore.Bosch.IboosterGen2

  defdelegate ready_to_drive?(), to: VmsCore.Bosch.IboosterGen2

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_cast(:on, state) do
    with  :ok <- FrontController.switch_on_ibooster(),
          :ok <- IboosterGen2.on()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_cast(:off, state) do
    with  :ok <- FrontController.switch_off_ibooster(),
          :ok <- IboosterGen2.off()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  def on() do
    GenServer.cast(__MODULE__, :on)
  end

  def off() do
    GenServer.cast(__MODULE__, :off)
  end
end
