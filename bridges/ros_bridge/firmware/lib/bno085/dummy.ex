defmodule BNO085.Dummy do
  use GenServer
  require Logger

  @impl true
  def init(_args) do
    {:ok, %{}}
  end

  def start_link(_opts) do
    Logger.debug("Starting #{__MODULE__}")
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def request_product_id(state) do
    # send_command(state, @sensor_hub_control_channel, << @product_id_request, 0x00 >> )
  end

  def enable_accelerometer(state) do
    # send_command(state, @sensor_hub_control_channel, << @set_feature_request, @accelerometer_report, 0x00, 0x00, 0x00, 0x60, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 >>)
  end

  def enable_uncalibrated_gyroscope(state) do
    # send_command(state, @sensor_hub_control_channel, << @set_feature_request, @uncalibrated_gyroscope_report, 0x00, 0x00, 0x00, 0x60, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 >>)
  end

  def enable_calibrated_gyroscope(state) do
    # send_command(state, @sensor_hub_control_channel, << @set_feature_request, @calibrated_gyroscope_report, 0x00, 0x00, 0x00, 0x60, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 >>)
  end
  @impl true
  def handle_cast(:test, state) do
    request_product_id(state)
    # enable_accelerometer(state)
    # enable_uncalibrated_gyroscope(state)
    # enable_calibrated_gyroscope(state)
    {:noreply, state}
  end

  def handle_cast(:reset, state) do
    # send_command(state, @executable_channel, << 0x01 >>)
    {:noreply, state}
  end
end

# {:ok, pid} = GenServer.start_link(BNO085.I2C, [])
# GenServer.cast(pid, :reset)
# Process.sleep(2000)
# GenServer.cast(pid, :test)
# Process.sleep(20000)
# GenServer.stop(pid)
