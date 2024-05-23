defmodule VmsCore.Abs do
  use GenServer
  alias Decimal, as: D
  alias Cantastic.Emitter

  defdelegate speed(), to: VmsCore.VwPolo.Abs

  @network_name :ovcs
  @abs_status_frame_name "abs_status"
  @speed_parameter "speed"
  @zero D.new(0)

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @abs_status_frame_name, %{
      parameters_builder_function: &abs_status_frame_parameter_builder/1,
      initial_data: %{
        @speed_parameter => @zero,
      }
    })
    :ok = Emitter.enable(@network_name, @abs_status_frame_name)
    {:ok, %{}}
  end

  defp abs_status_frame_parameter_builder(_) do
    {:ok, speed} = VmsCore.VwPolo.Abs.speed()
    parameters = %{@speed_parameter => speed}
    {:ok, parameters, parameters}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
end
