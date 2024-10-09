defmodule CvBridgex.CvCamera do
  use GenServer
  require Logger

  @loop_period 34

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: _process_name, device: device, topic: topic, props: props} = _args) do
    camera = get_opencv_camera(device, props)
    :ok = Rclex.start_node(topic)
    :ok = Rclex.start_publisher(Rclex.Pkgs.SensorMsgs.Msg.Image, "/#{topic}", topic, qos: Rclex.QoS.profile_sensor_data())
    {:ok, _timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      device: device,
      camera: camera,
      topic: topic,
      props: props
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    capture_and_send_picture(state)
    {:noreply, state}
  end

  defp get_opencv_camera(device, props) do
    camera = Evision.VideoCapture.videoCapture(device, apiPreference: Evision.VideoCaptureAPIs.cv_CAP_V4L)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FOURCC, Evision.VideoWriter.fourcc(List.first(~c"M"), List.first(~c"J"), List.first(~c"P"), List.first(~c"G")))
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_BUFFERSIZE, props.buffersize || 2)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FPS, props.fps || 30)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_WIDTH, props.width || 640)
    Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_HEIGHT, props.height || 480)
    camera
  end

  defp capture_and_send_picture(state) do
    picture = capture_with_opencv(state)
    case picture do
      nil ->
        Logger.warning("No picture in buffer")
      _ ->
        message = create_ros_image_message(picture)
        Rclex.publish(message, "/#{state.topic}", state.topic)
    end
  end

  defp capture_with_opencv(state) do
    if Evision.VideoCapture.isOpened(state.camera) do
      case Evision.VideoCapture.grab(state.camera) do
        false ->
          Logger.warning("Feed not available for camera #{state.device}")
          nil
        _ ->
          Evision.VideoCapture.retrieve(state.camera)
      end
    else
      nil
    end
  end

  defp create_ros_image_message(picture) do
    stamp         = %Rclex.Pkgs.BuiltinInterfaces.Msg.Time{sec: :os.timestamp() |> elem(1), nanosec: :os.timestamp() |> elem(2)}
    frame_id      = "OVCS"
    height        = picture.shape |> elem(0)
    width         = picture.shape |> elem(1)
    encoding      = "#{picture.type |> elem(1)}#{picture.type |> elem(0) |> to_string |> String.capitalize()}C#{picture.channels}"
    is_bigendian  = 0
    step          = (picture.shape |> elem(2)) * (picture.shape |> elem(1))
    data          = picture |> Evision.Mat.to_binary()

    %Rclex.Pkgs.SensorMsgs.Msg.Image{
      header: %Rclex.Pkgs.StdMsgs.Msg.Header{stamp: stamp, frame_id: frame_id},
      height: height,
      width: width,
      encoding: encoding,
      is_bigendian: is_bigendian,
      step: step,
      data: data
    }
  end
end
