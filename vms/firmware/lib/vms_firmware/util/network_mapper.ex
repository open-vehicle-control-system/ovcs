defmodule VmsFirmware.Util.NetworkMapper do
  require Logger

  def can_network_mappings(spi_mappings) do
    spi_mappings
    |> String.split(",", trim: true)
    |> Enum.map(fn(i) -> i |> String.split(":", trim: true) end)
    |> Enum.map(fn([network_name, spi_interface]) ->
        Task.async(fn() -> wait_for_spi(network_name, spi_interface) end)
      end)
    |> Task.await_many(12000)
  end

  defp wait_for_spi(network_name, spi_interface) do
    NervesUEvent.subscribe(["devices", "platform", "soc", :_, "spi_master", :_, spi_interface])
    Logger.info("Waiting for SPI #{spi_interface} device to be ready...")
    receive do
      %PropertyTable.Event{table: NervesUEvent, property: _, value: %{"ifindex" => _, "interface" => can_interface, "subsystem" => "net"}} = value ->
        Logger.info("SPI interface #{spi_interface} is ready and assigned to: #{network_name} => #{can_interface}")
        {network_name, can_interface}
    after
      10000 ->
        throw "SPI interface  '#{spi_interface}' to be used for '#{network_name}' not ready within 5 seconds, aborting!"
    end
  end
end
