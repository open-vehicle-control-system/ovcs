defmodule VmsCore.VwPolo.Engine do
  use GenServer
  alias Cantastic.Emitter

  @network_name :polo_drive

  @engine_status_frame_name "engine_status"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @engine_status_frame_name, %{
      parameters_builder_function: &status_frame_parameters_builder/1,
      initial_data: %{
        "engine_rotations_per_minute" => 0
      }
    })
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp status_frame_parameters_builder(state) do
    {:ok, state.data, state}
  end

  def rpm(rpm) do
    :ok = Emitter.update(@network_name, @engine_status_frame_name, fn (state) ->
      state |> put_in([:data, "engine_rotations_per_minute"], rpm)
    end)
  end

  def on() do
    Emitter.batch_enable(@network_name, [@engine_status_frame_name])
  end

  def off() do
    Emitter.batch_disable(@network_name, [@engine_status_frame_name])
  end
end
