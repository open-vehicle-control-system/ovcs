defmodule CvBridgex.CvCamera do
  use GenServer
  require Logger

  @delay 5

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: _process_name, device: device, capture_backend: capture_backend} = _args) do
    take_picture(@delay)
    camera = case capture_backend do
      :opencv ->
        get_opencv_camera(device)
      :ffmpeg ->
        get_ffmpeg_camera(device)
    end
    {:ok, %{
      device_id: device,
      camera: camera,
      latest_picture: nil,
      loop_active: true,
      capture_backend: capture_backend
    }}
  end

  @impl true
  def handle_call(:get_latest_picture, _from, state) do
    {:reply, {:ok, state.latest_picture}, state}
  end

  @impl true
  def handle_info(:take_picture, state) do
    picture = case state.capture_backend do
      :opencv ->
        capture_with_opencv(state)
      :ffmpeg ->
        capture_with_ffmpeg(state)
    end
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
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FOURCC, Evision.VideoWriter.fourcc(List.first('M'), List.first('J'), List.first('P'), List.first('G')))
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_BUFFERSIZE, 2)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_WIDTH, 800)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_HEIGHT, 600)
    camera
  end

  defp get_ffmpeg_camera(device_id) do
    Xav.Reader.new!("/dev/video#{device_id}", device?: true)
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

  defp capture_with_ffmpeg(state) do
    {:ok, %Xav.Frame{} = frame} = Xav.Reader.next_frame(state.camera)
    frame
  end
end
