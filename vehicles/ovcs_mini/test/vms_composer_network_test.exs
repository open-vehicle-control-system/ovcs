defmodule OvcsMini.Vms.ComposerNetworkTest do
  @moduledoc "Every CAN network the VMS composer hands a driver is declared in the vehicle's topology."
  use ExUnit.Case, async: true

  alias OvcsMini.Vms.Composer

  defp declared_networks do
    path = Path.join(:code.priv_dir(:ovcs_mini), Composer.can_config_path())
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
end
