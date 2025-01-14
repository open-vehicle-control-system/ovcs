defmodule Perception.ImageListener do
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
    state = GenServer.call(__MODULE__, :get_state)
    compressed_picture = Perception.LaneDetector.render(message.data)
    format = ".jpg"
    compressed_message = create_ros_compressed_image_message(compressed_picture, format, state)
    :ok = Rclex.publish(compressed_message, state.output_lane_topic, state.node_name)
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
