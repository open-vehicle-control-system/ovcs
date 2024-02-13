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
    :ok = Emitter.configure(@network_name, @calibration_frame_name, %{
      parameters_builder_function: &calibration_mode_request_frame_parameters/1,
      initial_data: %{
        @calibration_mode => false,
      }
    })
    Emitter.batch_enable(@network_name, [@calibration_frame_name])
    Cantastic.Receiver.subscribe(self(), @network_name, ["carControlsStatus"])
    {:ok, %{
      throttle: 0
      }
    }
  end

  def calibration_mode_request_frame_parameters(state) do
    {:ok, state.data, state}
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
  def handle_info({:handle_frame, %Frame{name: @car_controls_status_frame_name} = _frame, [throttle_signal] = _signals}, state) do
    IO.inspect "-----"
    IO.inspect throttle_signal
    throttle = convert_raw_throttle(throttle_signal.value)
    IO.inspect throttle
    {:noreply, %{state | throttle: throttle }}
  end

  defp convert_raw_throttle(raw_throttle) do
    raw_throttle / 2.55
  end

  @impl true
  def handle_call(:throttle, _from, state) do
    {:reply, state.throttle, state}
  end

  def throttle() do
    GenServer.call(__MODULE__, :throttle)
  end
end
