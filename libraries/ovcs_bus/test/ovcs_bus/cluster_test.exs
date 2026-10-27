defmodule OvcsBus.ClusterTest do
  use ExUnit.Case, async: true

  test "host dev node names carry the role in the sname" do
    assert OvcsBus.Cluster.role(:"ovcs-mini-vms@laptop", OvcsMini) == "vms"
    assert OvcsBus.Cluster.role(:"ovcs-mini-bridge-ros@laptop", OvcsMini) == "bridge-ros"
  end

  test "deployed node names carry the role in the hostname" do
    assert OvcsBus.Cluster.role(:"nerves@ovcs-mini-infotainment.local", OvcsMini) ==
             "infotainment"
  end

  test "a node outside the vehicle's naming keeps its full name" do
    assert OvcsBus.Cluster.role(:"peer-1@127.0.0.1", OvcsMini) == "peer-1@127.0.0.1"
  end
end
