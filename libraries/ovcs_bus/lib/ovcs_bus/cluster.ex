defmodule OvcsBus.Cluster do
  @moduledoc """
  Keeps every OVCS firmware BEAM for the active vehicle connected as
  an Erlang distribution cluster.

  The peer list is derived from the vehicle module's declared roles:

  * `vms` — every vehicle.
  * `infotainment` — vehicles that implement `infotainment/0`.
  * `bridge-<id>` — one per entry in `bridge_firmwares/0`.

  Node-name shape is inferred from `Node.self()`:

  * Host dev (`<vehicle>-<role>@<host>`) — peers share `<host>` and
    vary the sname. Example, for `ovcs1-vms@dev-laptop`:

        :"ovcs1-infotainment@dev-laptop"
        :"ovcs1-bridge-ros@dev-laptop"

  * Deployed Nerves (`nerves@<vehicle>-<role>.local`) — peers share
    the sname `nerves` and the domain suffix of the local hostname,
    and vary the hostname. Example, for `nerves@ovcs1-vms.local`:

        :"nerves@ovcs1-infotainment.local"
        :"nerves@ovcs1-bridge-ros.local"

  On a deployed firmware the node starts without a name;
  `OvcsBus.Distribution.ensure_started/0` names it on the first tick
  that succeeds. Until then the peer list is empty. Peers are derived
  again on every tick, so they follow `Node.self()`.

  Calls `Node.connect/1` on every peer at boot and retries on a
  `@retry_interval` timer, so a peer that comes up later is pulled
  into the mesh. `OvcsBus.broadcast/2` uses it only when
  `:cluster_broadcast` is set.
  """
  use GenServer
  require Logger

  @retry_interval 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    vehicle = Keyword.fetch!(opts, :vehicle)
    send(self(), :connect)
    {:ok, %{vehicle: vehicle, peers: []}}
  end

  @impl GenServer
  def handle_info(:connect, %{vehicle: vehicle} = state) do
    OvcsBus.Distribution.ensure_started()
    peers = peers_for(vehicle)
    self_node = Node.self()

    if peers != state.peers do
      Logger.info("OvcsBus.Cluster peers #{inspect(peers)} (self: #{inspect(self_node)})")
    end

    connected = Node.list()

    Enum.each(peers, fn peer ->
      cond do
        peer == self_node -> :ok
        peer in connected -> :ok
        true -> Node.connect(peer)
      end
    end)

    Process.send_after(self(), :connect, @retry_interval)
    {:noreply, %{state | peers: peers}}
  end

  @doc """
  Derive the peer node list for `vehicle_module` given the local
  node's naming convention.
  """
  @spec peers_for(module()) :: [node()]
  def peers_for(vehicle_module) do
    case Node.alive?() && String.split(Atom.to_string(Node.self()), "@", parts: 2) do
      [sname, hostname] ->
        vehicle_hyphen = vehicle_dir_hyphen(vehicle_module)
        roles = declared_roles(vehicle_module)

        if sname == "nerves" do
          # Deployed: role is encoded in hostname; the domain suffix
          # (`.local`) is shared.
          domain = domain_suffix(hostname)

          Enum.map(roles, fn role ->
            String.to_atom("nerves@#{vehicle_hyphen}-#{role}#{domain}")
          end)
        else
          # Host dev: role is encoded in sname; hostname is shared.
          Enum.map(roles, fn role ->
            String.to_atom("#{vehicle_hyphen}-#{role}@#{hostname}")
          end)
        end

      _ ->
        []
    end
  end

  @doc """
  Role of `node` within `vehicle_module`'s cluster, e.g. `"vms"` or
  `"bridge-ros"`.

  Reads the sname on host dev, or the first hostname label on a deployed
  firmware (sname `nerves`). A node outside the vehicle's naming keeps its
  full name.
  """
  @spec role(node(), module()) :: String.t()
  def role(node, vehicle_module) do
    full_name = Atom.to_string(node)
    prefix = vehicle_dir_hyphen(vehicle_module) <> "-"

    with [sname, hostname] <- String.split(full_name, "@", parts: 2),
         label = if(sname == "nerves", do: hostname |> String.split(".") |> hd(), else: sname),
         true <- String.starts_with?(label, prefix) do
      String.replace_prefix(label, prefix, "")
    else
      _ -> full_name
    end
  end

  # `"ovcs1-vms.local"` -> `".local"`; `"ovcs1-vms"` -> `""`.
  defp domain_suffix(hostname) do
    case String.split(hostname, ".", parts: 2) do
      [_host, domain] -> "." <> domain
      [_host] -> ""
    end
  end

  defp declared_roles(vehicle_module) do
    Code.ensure_loaded(vehicle_module)

    info_roles =
      if function_exported?(vehicle_module, :infotainment, 0), do: ["infotainment"], else: []

    bridge_roles =
      if function_exported?(vehicle_module, :bridge_firmwares, 0) do
        vehicle_module.bridge_firmwares()
        |> Map.keys()
        |> Enum.map(fn id -> "bridge-#{String.replace(id, "_", "-")}" end)
      else
        []
      end

    ["vms"] ++ info_roles ++ bridge_roles
  end

  defp vehicle_dir_hyphen(vehicle_module) do
    vehicle_module
    |> inspect()
    |> String.trim_leading("Elixir.")
    |> Macro.underscore()
    |> String.replace("_", "-")
  end
end
