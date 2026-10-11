defmodule Ovcs1.Vms.ComposerNetworkTest do
  @moduledoc "Every CAN network the VMS composer hands a driver is declared in the vehicle's topology."
  use ExUnit.Case, async: true

  alias Ovcs1.Vms.Composer
  alias VmsCore.Components.{Bosch, Evpt, Nissan, Orion, OVCS, Volkswagen}

  defp declared_networks do
    path = Path.join(:code.priv_dir(:ovcs1), Composer.can_config_path())
    {:ok, %{"can_networks" => networks}} = YamlElixir.read_from_file(path)
    networks |> Map.keys() |> Enum.map(&String.to_atom/1)
  end

  defp child_arguments do
    Enum.map(Composer.children(), fn
      {module, arguments} -> {module, arguments}
      %{start: {module, :start_link, [arguments]}} -> {module, arguments}
    end)
  end

  test "each network option names a declared network" do
    for {module, arguments} when is_map(arguments) <- child_arguments(),
        Map.has_key?(arguments, :network) do
      assert arguments.network in declared_networks(), "#{inspect(module)}: #{arguments.network}"
    end
  end

  test "every driver of a part on a vehicle network is given one" do
    networks =
      Map.new(child_arguments(), fn {module, arguments} -> {module, arguments[:network]} end)

    assert %{
             Volkswagen.Polo9N.Dashboard => :polo_drive,
             Volkswagen.Polo9N.ABS => :polo_drive,
             Volkswagen.Polo9N.PassengerCompartment => :polo_drive,
             Volkswagen.Polo9N.IgnitionLock => :polo_drive,
             Volkswagen.Polo9N.PowerSteeringPump => :misc,
             Nissan.LeafAZE0.Inverter => :leaf_drive,
             Orion.Bms2 => :orion_bms,
             Evpt.Evpt23Charger => :orion_bms,
             Bosch.IBoosterGen2 => :misc,
             OVCS.SteeringColumn => :misc
           } = networks
  end
end
