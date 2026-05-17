# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule BNO085.Dummy do
  use GenServer
  require Logger

  @accelerometer_cargo %{header: %{continuation: true, channel: 3, sequence_number: 145, cargo_length: 19}, reports: [%{id: 251, base_delta: 5}, %{id: 1, name: "accelerometer", status: 2, z: 2412, y: -39, x: -216, delay: 0, sequence_number: 72}]}
  @uncalibrated_gyroscope_cargo %{header: %{continuation: true, channel: 3, sequence_number: 45, cargo_length: 25}, reports: [%{id: 251, base_delta: 21}, %{id: 7, name: "uncalibrated_gyroscope", status: 0, z: 2, y: 0, x: -2, delay: 0, sequence_number: 150, x_bias: -2, y_bias: 0, z_bias: 2}]}
  @calibrated_gyroscope_cargo %{header: %{continuation: true, channel: 3, sequence_number: 25, cargo_length: 19}, reports: [%{id: 251, base_delta: 23}, %{id: 2, name: "calibrated_gyroscope", status: 0, z: 0, y: 1, x: 1, delay: 0, sequence_number: 12}]}
  # Static identity-quaternion-ish rotation (i=j=k=0, real=16383 ≈ Q14 1.0)
  # so the host stack receives a complete Imu sample without needing
  # a hardware-attached BNO085.
  @rotation_vector_cargo %{header: %{continuation: true, channel: 3, sequence_number: 30, cargo_length: 19}, reports: [%{id: 251, base_delta: 7}, %{id: 5, name: "rotation_vector", status: 3, sequence_number: 99, delay: 0, i: 0, j: 0, k: 0, real: 16383}]}
  @cargos [@accelerometer_cargo, @uncalibrated_gyroscope_cargo, @calibrated_gyroscope_cargo, @rotation_vector_cargo]
  @accelerometer_report 0x01
  @calibrated_gyroscope_report 0x02
  @rotation_vector_report 0x05
  @uncalibrated_gyroscope_report 0x07
  @published_report_ids [@accelerometer_report , @calibrated_gyroscope_report, @uncalibrated_gyroscope_report, @rotation_vector_report]

  @impl true
  def init(_args) do
    {:ok, _} = :timer.send_interval(10, :loop)
    {:ok, %{
      listeners: []
    }}
  end

  def start_link(_opts) do
    Logger.debug("Starting #{__MODULE__}")
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def handle_info(:loop, state) do
    @cargos |> Enum.each(fn cargo ->
      cargo.reports |> Enum.each(fn report ->
        if Enum.member?(@published_report_ids, report.id) do
          state.listeners |> Enum.each(fn listener ->
            GenServer.cast(listener, {:bno085_sensor_message, report})
          end)
        end
      end)
    end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def enable_all_sensors do
    :ok
  end

  def request_product_id do
    :ok
  end

  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end
end
