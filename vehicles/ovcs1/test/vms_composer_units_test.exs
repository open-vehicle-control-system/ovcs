defmodule Ovcs1.Vms.ComposerUnitsTest do
  @moduledoc "The VMS composer passes physical quantities under unit-named options."
  use ExUnit.Case, async: true

  alias Ovcs1.Vms.Composer
  alias VmsCore.Components.OVCS

  test "the contactors get the precharge voltage in volts" do
    arguments =
      Enum.find_value(Composer.children(), fn
        {OVCS.HighVoltageContactors, arguments} -> arguments
        _child -> nil
      end)

    assert arguments.required_precharge_output_voltage_v == 300
  end
end
