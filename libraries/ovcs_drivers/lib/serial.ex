defmodule OvcsDrivers.Serial do
  @moduledoc """
  Finds a USB serial adapter's device. Several adapters enumerate as
  `ttyUSB0`, `ttyUSB1`, ... in whichever order they come up, so a
  driver given `:serial_number` (the adapter's USB serial number, as
  `Circuits.UART.enumerate/0` lists it) opens that adapter whatever its
  name; given `:device` it opens that name.
  """

  @doc "The device name for `opts` (`:serial_number` or `:device`), or `{:error, reason}`."
  def device(opts) do
    case {Keyword.get(opts, :serial_number), Keyword.get(opts, :device)} do
      {nil, nil} -> {:error, "give :serial_number or :device"}
      {nil, device} -> {:ok, device}
      {serial_number, _} -> find(Circuits.UART.enumerate(), serial_number)
    end
  end

  @doc false
  def find(devices, serial_number) do
    case Enum.find(devices, fn {_name, info} -> Map.get(info, :serial_number) == serial_number end) do
      {name, _info} -> {:ok, name}
      nil -> {:error, "no serial adapter with serial number #{serial_number}"}
    end
  end
end
