defmodule VmsCore.Components.TuningOptionsTest do
  @moduledoc """
  Tuning values come from the composer's options, with defaults where a
  driver has one.

  `init/1` runs in the test process: a stand-in answers each Cantastic
  emitter and generic controller call, and with no receiver running on
  the test network, subscribing is a no-op.
  """
  use ExUnit.Case, async: false
  alias Cantastic.Interface
  alias Decimal, as: D
  alias VmsCore.Components.Bosch.IBoosterGen2
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter
  alias VmsCore.Components.OVCS.SteeringColumn

  @network :tuning_options_test

  defmodule StandIn do
    @moduledoc "Answers emitter and generic controller calls; every relay reads open."
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:get_digital_value, _pin}, _from, state), do: {:reply, {:ok, false}, state}
    def handle_call(_request, _from, state), do: {:reply, :ok, state}

    @impl GenServer
    def handle_cast(_request, state), do: {:noreply, state}
  end

  defp stand_in(name), do: start_supervised!({StandIn, name}, id: name)

  defp init!(driver, frame_names, arguments) do
    Enum.each(frame_names, &stand_in(Interface.emitter_process_name(@network, &1)))
    {:ok, state} = driver.init(Map.put(arguments, :network, @network))
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    state
  end

  describe "the Leaf inverter" do
    setup do
      stand_in(__MODULE__.Controller)

      state =
        init!(Inverter, ["vms_alive", "vms_torque_request", "vms_status"], %{
          selected_control_level_source: nil,
          selected_gear_source: nil,
          contact_source: nil,
          controller: __MODULE__.Controller,
          power_relay_pin: 7,
          drive_max_torque_nm: 120,
          reverse_max_torque_nm: 40
        })

      %{state: %{state | enabled: true, contact: :on}}
    end

    defp requested_torque(state, gear, throttle) do
      state = %{state | selected_gear: gear, requested_throttle: D.new(throttle)}
      {:noreply, state} = Inverter.handle_info(:loop, state)
      state.requested_torque
    end

    test "a full throttle requests the drive maximum, or the reverse one negated", %{state: state} do
      assert D.equal?(requested_torque(state, :drive, 1), 120)
      assert D.equal?(requested_torque(state, :reverse, 1), -40)
    end

    test "a request below the default threshold of 0.05 is zero", %{state: state} do
      assert D.equal?(requested_torque(state, :drive, "0.04"), 0)
      assert D.equal?(requested_torque(state, :drive, "0.05"), 6)
    end
  end

  describe "the steering column" do
    defp steering_column(arguments) do
      init!(
        SteeringColumn,
        ["lws_config"],
        Map.merge(
          %{
            selected_control_level_source: nil,
            power_relay_controller: nil,
            power_relay_pin: 6,
            actuation_controller: nil,
            direction_pin: 1,
            external_pwm_id: 0,
            max_steering_angle_deg: 400
          },
          arguments
        )
      )
    end

    test "stores the maximum angle and starts from the default tuning" do
      state = steering_column(%{})

      assert D.equal?(state.max_steering_angle_deg, 400)
      assert D.equal?(state.kp, D.new("0.07"))
      assert D.equal?(state.ki, D.new("0.005"))
      assert D.equal?(state.kd, D.new("0.005"))
      assert D.equal?(state.input_deadband, 0)
      assert D.equal?(state.input_alpha, D.new("0.2"))
    end

    test "starts from the tuning it is given" do
      state = steering_column(%{kp: "0.1", input_alpha: "0.5"})

      assert D.equal?(state.kp, D.new("0.1"))
      assert D.equal?(state.input_alpha, D.new("0.5"))
      assert D.equal?(state.ki, D.new("0.005"))
    end
  end

  describe "the iBooster" do
    defp booster(arguments) do
      init!(
        IBoosterGen2,
        ["vehicle_status", "vehicle_alive", "brake_request"],
        Map.merge(
          %{
            selected_control_level_source: nil,
            contact_source: nil,
            controller: nil,
            power_relay_pin: 5
          },
          arguments
        )
      )
    end

    test "starts from the default gains" do
      state = booster(%{})

      assert {D.to_integer(state.kp), D.to_integer(state.ki), D.to_integer(state.kd)} ==
               {250, 0, 0}
    end

    test "starts from the gains it is given" do
      state = booster(%{kp: 300, kd: "0.5"})
      assert D.equal?(state.kp, 300)
      assert D.equal?(state.kd, D.new("0.5"))
    end
  end
end
