defmodule BridgeFirmware.Util.NetworkMapper do
  @moduledoc """
  Wait-for-SPI-then-bind helper, identical in shape to the VMS one.
  Kept as its own module so each firmware image can reason about its
  own target-specific mappings without depending on the VMS lib.
  """
  require Logger

  def can_network_mappings(spi_mappings) do
    spi_mappings
    |> String.split(",", trim: true)
    |> Enum.map(fn entry -> String.split(entry, ":", trim: true) end)
    |> Enum.map(fn [network_name, interface] ->
      Task.async(fn -> wait_for_interface(network_name, interface) end)
    end)
    |> Task.await_many(20_000)
  end

  defp wait_for_interface(network_name, spi_interface)
       when binary_part(spi_interface, 0, 3) == "spi" do
    NervesUEvent.subscribe(["devices", "platform", "soc", :_, "spi_master", :_, spi_interface])

    match =
      NervesUEvent.match([
        "devices",
        "platform",
        "soc",
        :_,
        "spi_master",
        :_,
        spi_interface,
        "net",
        :_,
        :"$"
      ])

    case match do
      [] ->
        Logger.info("Waiting for SPI #{spi_interface}…")

        receive do
          %PropertyTable.Event{
            table: NervesUEvent,
            value: %{"interface" => can_interface, "subsystem" => "net"}
          } ->
            {network_name, can_interface, labels: [spi_interface: spi_interface]}
        after
          5_000 ->
            case File.ls("/sys/bus/spi/devices/#{spi_interface}/net") do
              {:ok, [can_interface]} ->
                {network_name, can_interface, labels: [spi_interface: spi_interface]}

              _ ->
                throw("SPI #{spi_interface} not ready within 5s for #{network_name}")
            end
        end

      [{_, %{"interface" => existing}}] ->
        {network_name, existing, labels: [spi_interface: spi_interface]}
    end
  end

  defp wait_for_interface(network_name, interface), do: {network_name, interface}
end
