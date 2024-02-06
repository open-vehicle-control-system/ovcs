defmodule OvcsEcu.NissanLeaf.Vms do
  alias OvcsEcu.{NissanLeaf.Util}
  alias Cantastic.{Frame, Emitter}

  @network_name "drive"

  @alive_frame_id "50B" |> Cantastic.Util.hex_to_integer()
  @alive_raw_data "000006C0000000" |> Cantastic.Util.hex_to_bin()
  @alive_frame     Frame.build(id: @alive_frame_id, network_name: @network_name, raw_data: @alive_raw_data)

  @torque_frame_id      "1D4" |> Cantastic.Util.hex_to_integer()
  @torque_frame_prefix "6E6E" |> Cantastic.Util.hex_to_bin()
  @torque_frame_suffix "4401" |> Cantastic.Util.hex_to_bin()

  @gear_mapping       %{drive: 4, neutral: 3, rear: 2, parked: 0}
  @eco_mode_mapping   %{on: 10, off: 0}
  @car_status_mapping %{on: 8, off: 4}

  @heartbeat_a "55" |> Cantastic.Util.hex_to_bin()
  @heartbeat_b "AA" |> Cantastic.Util.hex_to_bin()

  @status_filler   "C000" |> Cantastic.Util.hex_to_bin()
  @status_frame_id "11A" |> Cantastic.Util.hex_to_integer()

  def emitter_child_specs() do
    arguments = [
      %{
        process_name: VmsAliveFrameEmitter,
        frequency: 100,
        frame_sending_function: &alive_frame_sender/1,
        initial_data: nil,
        initialy_enabled: false
      },
      %{
        process_name: VmsTorqueFrameEmitter,
        frequency: 10,
        frame_sending_function: &torque_frame_sender/1,
        initial_data: %{torque: 0, counter: 0},
        initialy_enabled: false
      },
      %{
        process_name: VmsStatusFrameEmitter,
        frequency: 10,
        frame_sending_function: &status_frame_sender/1,
        initial_data: %{gear: :drive, car_status: :on, eco_mode: :off, counter: 0},
        initialy_enabled: false
      }
    ]
    arguments |> Enum.map(fn (args) ->
      Supervisor.child_spec({Emitter, args}, id: args.process_name)
    end)
  end

  def init_engine() do
    emitters = [VmsAliveFrameEmitter, VmsStatusFrameEmitter, VmsTorqueFrameEmitter]
    Emitter.batch_enable(emitters)
  end

  def throttle_engine(torque) do
    VmsTorqueFrameEmitter |> Emitter.update(fn (state) ->
      state |> put_in([:data, :torque], torque)
    end)
  end

  def alive_frame() do
    @alive_frame
  end

  def alive_frame_sender(state) do
    :ok = alive_frame() |> Frame.send()
    {:ok, state}
  end

  def torque_frame(torque, counter) do
    bin_torque  = torque |> Cantastic.Util.integer_to_bin_big()
    counter     = Util.shifted_counter(counter) |> Cantastic.Util.integer_to_bin_little(8)
    payload     = @torque_frame_prefix <> bin_torque <> counter <> @torque_frame_suffix
    crc         = Util.crc8(payload) |> Cantastic.Util.integer_to_bin_little(8)
    Frame.build(id: @torque_frame_id, network_name: @network_name, raw_data: payload <> crc)
  end

  def torque_frame_sender(state) do
    torque  = state.data.torque
    counter = state.data.counter
    frame = torque_frame(torque, counter)
    :ok = frame |> Frame.send()
    state = state |> put_in([:data, :counter], Util.counter(counter + 1))
    {:ok, state}
  end

  def status_frame(gear: gear, car_status: car_status, eco_mode: eco_mode, counter: counter) do
    gear                  = @gear_mapping[gear] |> Cantastic.Util.integer_to_bin_big(8)
    # Not sure how to use as DBC doc isnt consistent with working frame:
    _eco_mode              = @eco_mode_mapping[eco_mode] |> Cantastic.Util.integer_to_bin_big(8)
    _car_status            = @car_status_mapping[car_status] |> Cantastic.Util.integer_to_bin_big(8)
    # using filler instead in the meatime:
    filler                = "40" |> Cantastic.Util.hex_to_bin()
    steering_wheel_button = 0 |> Cantastic.Util.integer_to_bin_big(8)
    heartbeat             = heartbeat_value(counter)
    counter               = Util.counter(counter) |> Cantastic.Util.integer_to_bin_little(8)
    payload               = gear <> filler <> steering_wheel_button <> heartbeat <> @status_filler <> counter
    crc                   = Util.crc8(payload) |> Cantastic.Util.integer_to_bin_little(8)
    Frame.build(id: @status_frame_id, network_name: @network_name, raw_data: payload <> crc)
  end

  def status_frame_sender(state) do
    gear       = state.data.gear
    car_status = state.data.car_status
    eco_mode   = state.data.eco_mode
    counter    = state.data.counter
    frame = status_frame(gear: gear, car_status: car_status, eco_mode: eco_mode, counter: counter)
    :ok = frame |> Frame.send()
    state = state |> put_in([:data, :counter], Util.counter(counter + 1))
    {:ok, state}
  end

  defp heartbeat_value(counter) do
    case rem(counter, 2) == 0 do
      true  -> @heartbeat_a
      false -> @heartbeat_b
    end
  end
end
