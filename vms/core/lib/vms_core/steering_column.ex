defmodule VmsCore.SteeringColumn do
  use GenServer
  alias VmsCore.Controllers.{FrontController, ControlsController}

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_call({:on, duty_cycle, direction}, _from, state) do
    with  :ok <- ControlsController.set_steering_column_motor(duty_cycle, direction),
          :ok <- FrontController.switch_on_steering_column_motor()
    do
      {:reply, :ok, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_call(:off, _from, state) do
    with  :ok <- FrontController.switch_off_steering_column_motor()
    do
      {:reply, :ok, state}
    else
      :unexpected -> :unexpected
    end
  end

  def on(duty_cycle, direction) do
    GenServer.call(__MODULE__, {:on, duty_cycle, direction})
  end

  def off() do
    GenServer.call(__MODULE__, :off)
  end
end
