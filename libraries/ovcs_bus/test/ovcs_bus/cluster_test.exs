defmodule ClusterVisionVehicle do
  def vms, do: :vms
  def vision, do: :vision
end

defmodule ClusterPlainVehicle do
  def vms, do: :vms
end

defmodule OvcsBus.ClusterTest do
  use ExUnit.Case, async: false

  alias OvcsBus.Cluster

  setup do
    on_exit(fn -> Node.stop() end)
    :ok
  end

  defp start_node(name, type) do
    Node.stop()
    {:ok, _} = Node.start(name, type)
  end

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
    start_node(:"cluster-vision-vehicle-vms@127.0.0.1", :longnames)

    assert :"cluster-vision-vehicle-vision@127.0.0.1" in Cluster.peers_for(ClusterVisionVehicle)
  end

  test "peers include vision when the vehicle declares vision/0 (deployed)" do
    start_node(:"nerves@cluster-vision-vehicle-vms.local", :longnames)

    assert :"nerves@cluster-vision-vehicle-vision.local" in Cluster.peers_for(
             ClusterVisionVehicle
           )
  end

  test "peers exclude vision otherwise" do
    start_node(:"cluster-plain-vehicle-vms@127.0.0.1", :longnames)

    refute Enum.any?(
             Cluster.peers_for(ClusterPlainVehicle),
             &String.contains?(Atom.to_string(&1), "vision")
           )
  end
end
