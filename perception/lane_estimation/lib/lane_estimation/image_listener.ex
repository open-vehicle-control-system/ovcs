defmodule LaneEstimation.ImageListener do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{input_image_topic: input_image_topic, output_lane_topic: output_lane_topic, node_name: node_name} = _args) do
    :ok = Rclex.start_node(node_name)
    :ok = Rclex.start_subscription(
      &handle_image/1,
      Rclex.Pkgs.SensorMsgs.Msg.CompressedImage,
      input_image_topic,
      node_name,
      qos: Rclex.QoS.profile_sensor_data()
    )
    :ok = Rclex.start_publisher(
      Rclex.Pkgs.SensorMsgs.Msg.CompressedImage,
      output_lane_topic,
      node_name,
      qos: Rclex.QoS.profile_sensor_data()
    )
    {:ok, %{
      input_image_topic: input_image_topic,
      output_lane_topic: output_lane_topic,
      node_name: node_name
    }}
  end

  def handle_image(message) do
    mat = Evision.imdecode(message.data, Evision.Constant.cv_IMREAD_ANYCOLOR())
    lines = LaneDetector.new(mat)
    state = GenServer.call(__MODULE__, :get_state)
    if lines != [] do
      poly_img = Nx.broadcast(Nx.tensor([0], type: :u8), {mat.shape() |> elem(0), mat.shape() |> elem(1)}) |> Evision.Mat.from_nx()
      poly_img = Evision.merge([poly_img, poly_img, poly_img])
      max_y = mat.shape() |> elem(0)
      min_y = trunc(max_y/1.9)
      max_x = mat.shape() |> elem(1)
      min_x = 0
      polygon = LanePolygon.new(lines, min_y, max_y, min_x, max_x)
      format = ".jpg"
      if(polygon == []) do
        compressed_picture = Evision.imencode(format, poly_img)
        compressed_message = create_ros_compressed_image_message(compressed_picture, format, state)
        :ok = Rclex.publish(compressed_message, state.output_lane_topic, state.node_name)
      else
        points_as_mat = polygon |> Nx.tensor(type: :s32) |> Evision.Mat.from_nx()
        img = Evision.fillPoly(poly_img, [points_as_mat], {0, 255, 0})
        compressed_picture = Evision.imencode(format, img)
        compressed_message = create_ros_compressed_image_message(compressed_picture, format, state)
        :ok = Rclex.publish(compressed_message, state.output_lane_topic, state.node_name)
      end
    end
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  defp create_ros_compressed_image_message(compressed_picture, format, state) do
    stamp         = %Rclex.Pkgs.BuiltinInterfaces.Msg.Time{sec: :os.timestamp() |> elem(1), nanosec: :os.timestamp() |> elem(2)}
    %Rclex.Pkgs.SensorMsgs.Msg.CompressedImage{
      header: %Rclex.Pkgs.StdMsgs.Msg.Header{stamp: stamp, frame_id: state.output_lane_topic},
      format: format,
      data: compressed_picture
    }
  end
end
