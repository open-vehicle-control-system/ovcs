defmodule CvBridgex.CvCamera do
  use GenServer
  require Logger

  @delay 30

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: _process_name, device: device} = _args) do
    take_picture(@delay)
    camera = get_camera(device)
    {:ok, %{
      device_id: device,
      camera: camera,
      latest_picture: nil,
      loop_active: true
    }}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Evision.VideoCapture.release(state.camera)
    state = %{state | camera: nil, loop_active: false}
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    camera = get_camera(state.device_id)
    state = %{state | camera: camera, loop_active: true}
    take_picture(@delay)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:get_latest_picture, _from, state) do
    {:reply, {:ok, state.latest_picture}, state}
  end

  @impl true
  def handle_info(:take_picture, state) do
    picture = case state.loop_active do
      true ->
        picture = Evision.VideoCapture.read(state.camera)
        take_picture(@delay)
        picture
      false ->
        nil
    end
    {:noreply, %{state | latest_picture: picture}}
  end

  def stop(process_name) do
    GenServer.call(process_name, :stop)
  end

  def start(process_name) do
    GenServer.call(process_name, :start)
  end

  def get_latest_picture(process_name) do
    GenServer.call(process_name, :get_latest_picture)
  end

  defp get_camera(device_id) do
    Evision.VideoCapture.videoCapture(device_id)
  end

  defp take_picture(delay) do
    Process.send_after(self(), :take_picture, delay)
  end
end
