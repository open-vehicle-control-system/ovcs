defmodule VmsFirmware.Util.NetworkMapper do
  require Logger

  def can_network_mappings(spi_mappings) do
    spi_mappings
    |> String.split(",", trim: true)
    |> Enum.map(fn(i) -> i |> String.split(":", trim: true) end)
    |> Enum.map(fn([network_name, interface]) ->
        Task.async(fn() -> wait_for_interface(network_name, interface) end)
      end)
    |> Task.await_many(20000)
  end

  defp wait_for_interface(network_name, spi_interface) when binary_part(spi_interface, 0, 3) == "spi" do
    NervesUEvent.subscribe(["devices", "platform", "soc", :_, "spi_master", :_, spi_interface])
    match = NervesUEvent.match(["devices", "platform", "soc", :_, "spi_master", :_, spi_interface, "net", :_, :"$"])
    case match do
      [] ->
        Logger.info("Waiting for SPI #{spi_interface} device to be ready...")
        receive do
          %PropertyTable.Event{table: NervesUEvent, property: _, value: %{"ifindex" => _, "interface" => can_interface, "subsystem" => "net"}} = value ->
            Logger.info("SPI interface #{spi_interface} is ready and assigned to: #{network_name} => #{can_interface}")
            {network_name, can_interface}
        after
          5000 ->
            case File.ls("/sys/bus/spi/devices/#{spi_interface}/net") do
              {:ok, [can_interface]} ->
                Logger.info("SPI interface #{spi_interface} is ready according to /sys/bus/spi/devices/ and assigned to: #{network_name} => #{can_interface}")
                {network_name, can_interface}
              _ ->
                throw "SPI interface  '#{spi_interface}' to be used for '#{network_name}' not ready within 5 seconds, aborting!"
            end
        end
      [{_, %{"interface" => existing_can_interface}}] ->
        Logger.info("SPI interface #{spi_interface} was already and assigned to: #{network_name} => #{existing_can_interface}")
        {network_name, existing_can_interface}
    end
  end
  defp wait_for_interface(network_name, interface) do
    {network_name, interface}
  end
end
