defmodule OvcsInfotainmentBackend.VehicleStateManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_frame(frame, signals) do
    GenServer.cast(__MODULE__, {:handle_frame, frame, signals})
  end

  @impl true
  def init([vehicle_config]) do
    {:ok,
      %{
        "model" => vehicle_config["model"],
        "brand" => vehicle_config["brand"],
        "handbrakeEngaged" => initial_signal_state()
      }
    }
  end

  @impl true
  def handle_cast({:handle_frame, frame, signals}, state) do
    IO.inspect frame
    IO.inspect signals
    signals |> Enum.each(fn(signal) ->
      OvcsInfotainmentBackendWeb.Endpoint.broadcast!("debug-metrics", "update_handbrake", signal)
    end)
    {:noreply, state}
  end

  defp initial_signal_state() do
    %{updated: nil, value: nil}
  end
end
