defmodule InfotainmentCore.ContactorsStatus do
  use GenServer
  require Logger

  alias Cantastic.{ReceivedFrameWatcher, Frame, Signal}

  @network_name :ovcs
  @rear_controller_status_frame_name "rear_controller_digital_and_analog_pin_status"

  @impl true
  def init(_) do
    :ok = ReceivedFrameWatcher.subscribe(@network_name, @rear_controller_status_frame_name, self())
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, [
      @rear_controller_status_frame_name,
    ])
    enable_watchers()
    {:ok, %{
      main_negative_off: true,
      main_positive_off: true,
      precharge_off: true
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_missing_frame,  _network_name, frame_name}, state) do
    #Logger.warning("Frame #{network_name}.#{frame_name} is missing")
    case frame_name do
      @rear_controller_status_frame_name -> {:noreply, %{state |
        main_negative_off: true,
        main_positive_off: true,
        precharge_off: true
      }}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: @rear_controller_status_frame_name, signals: signals}}, state) do
    %{
      "digital_pin3_enabled" => %Signal{value: main_negative_on},
      "digital_pin4_enabled" => %Signal{value: main_positive_on},
      "digital_pin5_enabled" => %Signal{value: precharge_on},
    } = signals
    {:noreply, %{state |
        main_negative_off: !main_negative_on,
        main_positive_off: !main_positive_on,
        precharge_off: !precharge_on,
      }
    }
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(@network_name, @rear_controller_status_frame_name)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      main_negative_off: state.main_negative_off,
      main_positive_off: state.main_positive_off,
      precharge_off: state.precharge_off,
    }
    {:reply, {:ok, status}, state}
  end

  defp enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end

  def status() do
    GenServer.call(__MODULE__, :status)
  end
end
