defmodule VmsCore.BatteryManagementSystem do
  use GenServer
  alias VmsCore.Controllers.ContactorsController
  alias VmsCore.Orion
  alias Cantastic.Emitter
  alias Decimal, as: D

  @network_name :ovcs
  @bms_status_frame_name "bms_status"
  @zero D.new(0)

  defdelegate allowed_power(), to: Orion.Bms2
  defdelegate ac_input_voltage(ac_input_voltage), to: Orion.Bms2

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @bms_status_frame_name, %{
      parameters_builder_function: &bms_status_frame_parameter_builder/1,
      initial_data: %{
        "adaptative_state_of_charge" => @zero,
        "operating_mode" => "power",
        "instant_consumption" => @zero,
        "state_of_health" => @zero,
        "autonomy" => @zero,
        "charging_power" => @zero
      }
    })
    :ok = Emitter.enable(@network_name, @bms_status_frame_name)
    {:ok, %{}}
  end

  defp bms_status_frame_parameter_builder(_) do
    {:ok, status} = Orion.Bms2.status()
    parameters = %{
      "adaptative_state_of_charge" => status.adaptative_state_of_charge,
      "operating_mode" => operating_mode(status.charge_interlock_enabled),
      "instant_consumption" => @zero,
      "state_of_health" => status.state_of_health,
      "autonomy" => @zero,
      "charging_power" => charging_power(status.pack_current, status.pack_instant_voltage, status.charge_interlock_enabled)
    }
    {:ok, parameters, parameters}
  end

  defp charging_power(pack_current, pack_instant_voltage, charge_interlock_enabled) do
    case charge_interlock_enabled do
      true -> D.mult(pack_current, pack_instant_voltage) |> D.div(1000)
      false -> @zero
    end
  end

  defp operating_mode(interlock_enabled) do
    case interlock_enabled do
      true -> "charging"
      false -> "power"
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_cast(:high_voltage_on, state) do
    with :ok <- ContactorsController.on()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_cast(:high_voltage_off, state) do
    with :ok <- ContactorsController.off()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end


  def high_voltage_on() do
    GenServer.cast(__MODULE__, :high_voltage_on)
  end

  def high_voltage_off() do
    GenServer.cast(__MODULE__, :high_voltage_off)
  end

  def ready_to_drive?() do
    {:ok, contactors_controller_ready} = ContactorsController.ready_to_drive?()
    {:ok, bms_ready}                   = Orion.Bms2.ready_to_drive?()
    {:ok, contactors_controller_ready && bms_ready}
  end
end
