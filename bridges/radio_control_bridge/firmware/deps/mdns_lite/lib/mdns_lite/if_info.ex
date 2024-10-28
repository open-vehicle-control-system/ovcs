defmodule MdnsLite.IfInfo do
  @moduledoc false

  # TODO: Delete module
  defstruct ipv4_address: nil, ipv6_addresses: []

  @type t() :: %__MODULE__{
          ipv4_address: :inet.ip4_address() | nil,
          ipv6_addresses: [:inet.ip6_address()]
        }
end
