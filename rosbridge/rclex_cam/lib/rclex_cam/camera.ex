defmodule RclexCam.Camera do
  use GenServer
  require Logger

  @default_fps    25
  @default_width  640
  @default_height 480
  @default_buffer_size 2

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name: _process_name, device: device, topic: topic, frame_id: frame_id, props: props} = _args) do
    camera = get_opencv_camera(device, props)
    start_ros_node_and_publisher(topic)
    start_timer(props)
    {:ok, %{
      device: device,
      camera: camera,
      topic: topic,
      frame_id: frame_id,
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
    mjpg = Evision.VideoWriter.fourcc(List.first(~c"M"), List.first(~c"J"), List.first(~c"P"), List.first(~c"G"))
    true = Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FOURCC, mjpg)
    case props do
      nil ->
        true
      _ ->
        set_camera_props(camera, props)
    end
    camera
  end

  defp start_ros_node_and_publisher(topic) do
    :ok = Rclex.start_node(topic)
    :ok = Rclex.start_publisher(Rclex.Pkgs.SensorMsgs.Msg.Image, "/#{topic}_raw", topic, qos: Rclex.QoS.profile_sensor_data())
    :ok = Rclex.start_publisher(Rclex.Pkgs.SensorMsgs.Msg.CompressedImage, "/#{topic}_compressed", topic, qos: Rclex.QoS.profile_sensor_data())
  end

  defp start_timer(props) do
    fps = case props do
      nil ->
        @default_fps
      _ ->
        Map.get(props, :fps, @default_fps)
    end
    loop_timer = (1000/fps) |> ceil |> trunc
    {:ok, _timer} = :timer.send_interval(loop_timer, :loop)
  end

  defp set_camera_props(camera, props) do
    buffersize = Map.get(props, :buffersize, @default_buffer_size)
    fps        = Map.get(props, :fps, @default_fps)
    width      = Map.get(props, :width, @default_width)
    height     = Map.get(props, :height, @default_height)
    true = Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_BUFFERSIZE, buffersize)
    true = Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FPS, fps)
    true = Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_WIDTH, width)
    true = Evision.VideoCapture.set(camera, Evision.VideoCaptureProperties.cv_CAP_PROP_FRAME_HEIGHT, height)
  end

  defp capture_and_send_picture(state) do
    picture = capture_with_opencv(state)
    case picture do
      nil ->
        Logger.warning("No picture in buffer")
      _ ->
        format = ".jpg"
        compressed_picture = Evision.imencode(format, picture)
        message = create_ros_image_message(picture, state)
        compressed_message = create_ros_compressed_image_message(compressed_picture, format, state)
        Rclex.publish(message, "/#{state.topic}_raw", state.topic)
        Rclex.publish(compressed_message, "/#{state.topic}_compressed", state.topic)
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

  defp create_ros_image_message(picture, state) do
    stamp         = %Rclex.Pkgs.BuiltinInterfaces.Msg.Time{sec: :os.timestamp() |> elem(1), nanosec: :os.timestamp() |> elem(2)}
    frame_id      = state.frame_id || state.topic
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

  defp create_ros_compressed_image_message(compressed_picture, format, state) do
    stamp         = %Rclex.Pkgs.BuiltinInterfaces.Msg.Time{sec: :os.timestamp() |> elem(1), nanosec: :os.timestamp() |> elem(2)}
    frame_id      = state.frame_id || state.topic
    %Rclex.Pkgs.SensorMsgs.Msg.CompressedImage{
      header: %Rclex.Pkgs.StdMsgs.Msg.Header{stamp: stamp, frame_id: frame_id},
      format: format,
      data: compressed_picture
    }
  end
end
