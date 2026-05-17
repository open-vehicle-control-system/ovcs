defmodule Obd2.Vms.PidCatalog do
  @moduledoc """
  SAE J1979 Mode 0x01 PID catalog used by the discovery scanner to
  attach a human-readable name to each supported PID bit.

  The catalog is intentionally minimal: it only carries the PID number,
  display name and (where applicable) unit. Decoding scale and offset
  for live polling stays in YAML so cantastic owns the wire format and
  the catalog stays cheap to extend.
  """

  @entries %{
    0x01 => %{name: "Monitor status since DTCs cleared", unit: nil},
    0x02 => %{name: "Freeze DTC", unit: nil},
    0x03 => %{name: "Fuel system status", unit: nil},
    0x04 => %{name: "Calculated engine load", unit: "%"},
    0x05 => %{name: "Engine coolant temperature", unit: "°C"},
    0x06 => %{name: "Short term fuel trim — bank 1", unit: "%"},
    0x07 => %{name: "Long term fuel trim — bank 1", unit: "%"},
    0x08 => %{name: "Short term fuel trim — bank 2", unit: "%"},
    0x09 => %{name: "Long term fuel trim — bank 2", unit: "%"},
    0x0A => %{name: "Fuel pressure", unit: "kPa"},
    0x0B => %{name: "Intake manifold absolute pressure", unit: "kPa"},
    0x0C => %{name: "Engine RPM", unit: "rpm"},
    0x0D => %{name: "Vehicle speed", unit: "km/h"},
    0x0E => %{name: "Timing advance", unit: "°"},
    0x0F => %{name: "Intake air temperature", unit: "°C"},
    0x10 => %{name: "Mass air flow rate", unit: "g/s"},
    0x11 => %{name: "Throttle position", unit: "%"},
    0x12 => %{name: "Commanded secondary air status", unit: nil},
    0x13 => %{name: "Oxygen sensors present (2 banks)", unit: nil},
    0x14 => %{name: "O2 sensor 1, bank 1", unit: "V"},
    0x15 => %{name: "O2 sensor 2, bank 1", unit: "V"},
    0x16 => %{name: "O2 sensor 3, bank 1", unit: "V"},
    0x17 => %{name: "O2 sensor 4, bank 1", unit: "V"},
    0x18 => %{name: "O2 sensor 1, bank 2", unit: "V"},
    0x19 => %{name: "O2 sensor 2, bank 2", unit: "V"},
    0x1A => %{name: "O2 sensor 3, bank 2", unit: "V"},
    0x1B => %{name: "O2 sensor 4, bank 2", unit: "V"},
    0x1C => %{name: "OBD standard conformance", unit: nil},
    0x1D => %{name: "Oxygen sensors present (4 banks)", unit: nil},
    0x1E => %{name: "Auxiliary input status", unit: nil},
    0x1F => %{name: "Run time since engine start", unit: "s"},
    0x21 => %{name: "Distance with MIL on", unit: "km"},
    0x22 => %{name: "Fuel rail pressure (vacuum)", unit: "kPa"},
    0x23 => %{name: "Fuel rail gauge pressure", unit: "kPa"},
    0x2C => %{name: "Commanded EGR", unit: "%"},
    0x2D => %{name: "EGR error", unit: "%"},
    0x2E => %{name: "Commanded evaporative purge", unit: "%"},
    0x2F => %{name: "Fuel tank level", unit: "%"},
    0x30 => %{name: "Warm-ups since codes cleared", unit: nil},
    0x31 => %{name: "Distance since codes cleared", unit: "km"},
    0x32 => %{name: "Evap. system vapor pressure", unit: "Pa"},
    0x33 => %{name: "Absolute barometric pressure", unit: "kPa"},
    0x3C => %{name: "Catalyst temperature, bank 1, sensor 1", unit: "°C"},
    0x3D => %{name: "Catalyst temperature, bank 2, sensor 1", unit: "°C"},
    0x3E => %{name: "Catalyst temperature, bank 1, sensor 2", unit: "°C"},
    0x3F => %{name: "Catalyst temperature, bank 2, sensor 2", unit: "°C"},
    0x42 => %{name: "Control module voltage", unit: "V"},
    0x43 => %{name: "Absolute engine load", unit: "%"},
    0x44 => %{name: "Commanded equivalence ratio", unit: nil},
    0x45 => %{name: "Relative throttle position", unit: "%"},
    0x46 => %{name: "Ambient air temperature", unit: "°C"},
    0x47 => %{name: "Absolute throttle position B", unit: "%"},
    0x48 => %{name: "Absolute throttle position C", unit: "%"},
    0x49 => %{name: "Accelerator pedal position D", unit: "%"},
    0x4A => %{name: "Accelerator pedal position E", unit: "%"},
    0x4B => %{name: "Accelerator pedal position F", unit: "%"},
    0x4C => %{name: "Commanded throttle actuator", unit: "%"},
    0x4D => %{name: "Time run with MIL on", unit: "min"},
    0x4E => %{name: "Time since trouble codes cleared", unit: "min"},
    0x51 => %{name: "Fuel type", unit: nil},
    0x52 => %{name: "Ethanol fuel %", unit: "%"},
    0x53 => %{name: "Absolute evap system vapor pressure", unit: "kPa"},
    0x5A => %{name: "Relative accelerator pedal position", unit: "%"},
    0x5B => %{name: "Hybrid battery pack remaining life", unit: "%"},
    0x5C => %{name: "Engine oil temperature", unit: "°C"},
    0x5D => %{name: "Fuel injection timing", unit: "°"},
    0x5E => %{name: "Engine fuel rate", unit: "L/h"}
  }

  @type entry :: %{name: String.t(), unit: String.t() | nil}

  @doc """
  Returns `%{name: ..., unit: ...}` for a known PID, or
  `%{name: "Unknown PID 0x..", unit: nil}` for one that isn't catalogued.

  This way the discovery dashboard can list every supported PID without
  having to ship a bitmap-keyed translation in the frontend.
  """
  @spec lookup(non_neg_integer()) :: entry()
  def lookup(pid) when is_integer(pid) do
    case Map.fetch(@entries, pid) do
      {:ok, entry} -> entry
      :error -> %{name: "Unknown PID 0x#{pad_hex(pid)}", unit: nil}
    end
  end

  @doc """
  Decodes one of cantastic's `pids_xx_to_yy` 32-bit bitmasks (returned by
  Mode 01 PID 0x00 / 0x20 / …) into the list of supported PID numbers
  inside that range.

  The bitmask's MSB represents the PID right after the requested one
  (so `pids_01_to_20`'s top bit is PID 0x01), per ISO 15031-5 §7.2.
  """
  @spec decode_bitmask(bitstring(), non_neg_integer()) :: [non_neg_integer()]
  def decode_bitmask(<<bitmask::big-unsigned-integer-size(32)>>, base_pid) do
    for offset <- 0..31, Bitwise.band(Bitwise.bsr(bitmask, 31 - offset), 1) == 1 do
      base_pid + offset + 1
    end
  end

  def decode_bitmask(_other, _base_pid), do: []

  defp pad_hex(value) do
    value |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
  end
end
