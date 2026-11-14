defmodule VmsCore.NetworkInterfacesTest do
  use ExUnit.Case, async: true

  alias VmsCore.NetworkInterfaces

  test "a missing interface has no statistics instead of crashing the poll" do
    state = %{network_interfaces: [%{interface: "__ovcs_missing_interface__", statistics: %{}}]}

    assert {:reply, {:ok, [%{statistics: %{}} = interface]}, ^state} =
             NetworkInterfaces.handle_call(:network_interfaces, nil, state)

    assert interface.statistics == %{}
  end

  test "a missing interface does not hide the loopback interface" do
    state = %{
      network_interfaces: [
        %{interface: "__ovcs_missing_interface__", statistics: %{}},
        %{interface: "lo", statistics: %{}}
      ]
    }

    assert {:reply, {:ok, [missing, available]}, ^state} =
             NetworkInterfaces.handle_call(:network_interfaces, nil, state)

    assert missing.statistics == %{}
    assert available.statistics["ifname"] == "lo"
    assert is_map(available.statistics["stats64"])
  end
end
