defmodule OvcsEcu.OvcsControllers.CarControlsController do
  use GenServer
  alias Cantastic.{Frame, Emitter}

  @network_name "drive"
  @calibration_frame_name "carControlsCalibrationModeRequest"
  @car_controls_status_frame_name "carControlsStatus"
  @calibration_mode "calibrationModeEnabled"

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), @network_name, ["carControlsStatus"])
    {:ok, %{
      throttle: 0
      }
    }
  end

  def enable_calibration_mode() do
    switch_calibration(true)
  end

  def disable_calibration_mode() do
    switch_calibration(false)
  end

  defp switch_calibration(enable) do
    Emitter.update(@network_name, @calibration_frame_name, fn (state) ->
      state |> put_in([:data, @calibration_mode], enable)
    end)
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @car_controls_status_frame_name} = _frame, [raw_max_throttle_signal, raw_throttle_a, raw_throttle_b] = _signals}, state) do
    IO.inspect "-----"
    IO.inspect raw_max_throttle_signal
    IO.inspect raw_throttle_a
    IO.inspect raw_throttle_b
    throttle = 0
    {:noreply, %{state | throttle: throttle }}
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, state.throttle, state}
  end

  def throttle() do
    GenServer.call(__MODULE__, :throttle)
  end
end
