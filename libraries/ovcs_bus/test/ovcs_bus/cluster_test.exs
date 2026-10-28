defmodule ClusterVisionVehicle do
  def vms, do: :vms
  def vision, do: :vision
end

defmodule ClusterPlainVehicle do
  def vms, do: :vms
end

defmodule OvcsBus.ClusterTest do
  use ExUnit.Case, async: true

  alias OvcsBus.Cluster

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

  test "peers include vision when the vehicle declares vision/0 (host dev)" do
    assert :"cluster-vision-vehicle-vision@127.0.0.1" in Cluster.peers_for(
             ClusterVisionVehicle,
             :"cluster-vision-vehicle-vms@127.0.0.1"
           )
  end

  test "peers include vision when the vehicle declares vision/0 (deployed)" do
    assert :"nerves@cluster-vision-vehicle-vision.local" in Cluster.peers_for(
             ClusterVisionVehicle,
             :"nerves@cluster-vision-vehicle-vms.local"
           )
  end

  test "peers exclude vision otherwise" do
    refute Enum.any?(
             Cluster.peers_for(ClusterPlainVehicle, :"cluster-plain-vehicle-vms@127.0.0.1"),
             &String.contains?(Atom.to_string(&1), "vision")
           )
  end
end
