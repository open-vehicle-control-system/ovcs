defmodule OvcsEcu.NissanLeaf.Vms do
  alias OvcsEcu.{NissanLeaf.Util}
  alias Cantastic.Frame

  @network_name "drive"

  @alive_frame_id "50B" |> Cantastic.Util.hex_to_integer()
  @alive_raw_data "000006C0000000" |> Cantastic.Util.hex_to_bin()
  @alive_frame     Frame.build(id: @alive_frame_id, network_name: @network_name, raw_data: @alive_raw_data, data_length: 8)

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

  def alive_frame() do
    @alive_frame
  end

  def torque_frame(torque, counter) do
    bin_torque  = torque |> Cantastic.Util.integer_to_bin_big()
    counter     = Util.shifted_counter(counter) |> Cantastic.Util.integer_to_bin_little(8)
    payload     = @torque_frame_prefix <> bin_torque <> counter <> @torque_frame_suffix
    crc         = Util.crc8(payload) |> Cantastic.Util.integer_to_bin_little(8)
    Frame.build(id: @torque_frame_id, network_name: @network_name, raw_data: payload <> crc, data_length: 8)
  end

  def status_frame(gear: gear, car_status: car_status, eco_mode: eco_mode, counter: counter) do
    gear                  = @gear_mapping[gear] |> Cantastic.Util.integer_to_bin_big(8)
    # Not sure how to use
    _eco_mode              = @eco_mode_mapping[eco_mode] |> Cantastic.Util.integer_to_bin_big(8)
    _car_status            = @car_status_mapping[car_status] |> Cantastic.Util.integer_to_bin_big(8)
    # end
    filler                = "40" |> Cantastic.Util.hex_to_bin()
    steering_wheel_button = 0 |> Cantastic.Util.integer_to_bin_big(8)
    heartbeat             = heartbeat_value(counter)
    counter               = Util.counter(counter) |> Cantastic.Util.integer_to_bin_little(8)
    payload               = gear <> filler <> steering_wheel_button <> heartbeat <> @status_filler <> counter
    crc                   = Util.crc8(payload) |> Cantastic.Util.integer_to_bin_little(8)
    Frame.build(id: @status_frame_id, network_name: @network_name, raw_data: payload <> crc, data_length: 8)
  end

  def heartbeat_value(counter) do
    case rem(counter, 2) == 0 do
      true  -> @heartbeat_a
      false -> @heartbeat_b
    end
  end
end
