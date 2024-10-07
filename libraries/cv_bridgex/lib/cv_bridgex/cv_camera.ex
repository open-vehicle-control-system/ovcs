defmodule CvBridgex.CvCamera do
  use GenServer
  require Logger

  @delay 20

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: _process_name, device: device} = _args) do
    take_picture(@delay)
    camera = get_opencv_camera(device)
    {:ok, %{
      device_id: device,
      camera: camera,
      latest_picture: nil,
      loop_active: true,
    }}
  end

  @impl true
  def handle_call(:get_latest_picture, _from, state) do
    {:reply, {:ok, state.latest_picture}, state}
  end

  @impl true
  def handle_info(:take_picture, state) do
    picture = capture_with_opencv(state)
    {:noreply, %{state | latest_picture: picture}}
  end

  def get_latest_picture(process_name) do
    GenServer.call(process_name, :get_latest_picture)
  end

  defp take_picture(delay) do
    Process.send_after(self(), :take_picture, delay)
  end

  defp get_opencv_camera(device_id) do
    camera = Evision.VideoCapture.videoCapture(device_id, apiPreference: Evision.VideoCaptureAPIs.cv_CAP_V4L)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FOURCC, Evision.VideoWriter.fourcc(List.first(~c"M"), List.first(~c"J"), List.first(~c"P"), List.first(~c"G")))
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_BUFFERSIZE, 2)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FPS, 30)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_WIDTH, 640)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_HEIGHT, 480)
    camera
  end

  defp capture_with_opencv(state) do
    if Evision.VideoCapture.isOpened(state.camera) do
      case state.loop_active do
        true ->
          picture = case Evision.VideoCapture.grab(state.camera) do
            false ->
              Logger.warning("Feed not available for camera #{state.device_id}")
              nil
            _ ->
              take_picture(@delay)
              Evision.VideoCapture.retrieve(state.camera)
          end
          picture
        false ->
          nil
      end
    end
  end
end
