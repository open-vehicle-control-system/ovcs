defmodule VintageNet.Technology.Gadget do
  @moduledoc """
  Deprecated - Use VintageNetDirect now

  This module will automatically redirect your configurations to VintageNetDirect so
  no changes are needed to your code. New code should use the new module.
  """
  @behaviour VintageNet.Technology

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__} = config) do
    config
    |> update_config
    |> VintageNetDirect.normalize()
  end

  @impl VintageNet.Technology
  def to_raw_config(ifname, config, opts) do
    updated_config = update_config(config)
    VintageNetDirect.to_raw_config(ifname, updated_config, opts)
  end

  defp update_config(config) do
    gadget = Map.get(config, :gadget, %{})

    %{type: VintageNetDirect, vintage_net_direct: gadget}
  end

  @impl VintageNet.Technology
  defdelegate ioctl(ifname, command, args), to: VintageNetDirect

  @impl VintageNet.Technology
  defdelegate check_system(opts), to: VintageNetDirect
end
