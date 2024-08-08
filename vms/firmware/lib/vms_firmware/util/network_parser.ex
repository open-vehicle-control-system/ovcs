defmodule VmsFirmware.Util.NetworkParser do
  require Logger

  def parse(spi_mappings) do
    spi_mappings
    |> String.split(",", trim: true)
    |> Enum.map(fn(network_configuration) ->
      [network_name, spi_interface] = String.split(network_configuration, ":", trim: true)
      Task.async(fn() -> wait_for_spi(network_name, spi_interface) end)
    end)
    |> Task.await_many()
    |> Enum.map(fn({:ok, network_name, can_interface}) ->
      network_name <> ":" <> can_interface
    end)
  end

  defp wait_for_spi(network_name, spi_interface) do
    NervesUEvent.subscribe(["devices", "platform", "soc", :_, "spi_master", :_, spi_interface])
    Logger.info("Waiting for SPI #{spi_interface} device to be ready...")
    receive do
      %PropertyTable.Event{table: NervesUEvent, property: _, value: %{"ifindex" => _, "interface" => can_interface, "subsystem" => "net"}} = value ->
        Logger.info("SPI interface #{spi_interface} is ready")
        {:ok, network_name, can_interface}
    after
      5000 ->
        Logger.info("SPI device not detected, aborting...")
        :error
    end
  end
end
