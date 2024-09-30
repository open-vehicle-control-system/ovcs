defmodule CvBridgex.CvCamera do
  use GenServer
  require Logger

  @delay 1000

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    take_picture(@delay)
    camera = get_camera()
    {:ok, %{
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
    camera = get_camera()
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

  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  def start() do
    GenServer.call(__MODULE__, :start)
  end

  def get_latest_picture() do
    GenServer.call(__MODULE__, :get_latest_picture)
  end

  defp get_camera() do
    Evision.VideoCapture.videoCapture(0) # Assumes for now that there is only one cam connected
  end

  defp take_picture(delay) do
    Process.send_after(self(), :take_picture, delay)
  end
end
