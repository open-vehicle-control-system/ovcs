defmodule OneDHCPD.Message do
  @moduledoc """
  DHCP Message

  See [RFC2131](https://tools.ietf.org/html/rfc2131) and associated docs
  for details. This implementation is only intended to be complete enough
  to support the OneDHCPD use case.
  """
  import OneDHCPD.Utility

  alias OneDHCPD.Options

  @magic_cookie <<99, 130, 83, 99>>
  @bootrequest 1
  @bootreply 2
  @htype_ether 1
  # @htype_ieee802 6
  # @htype_fddi 8

  defstruct op: @bootrequest,
            htype: @htype_ether,
            hops: 0,
            xid: 0,
            secs: 0,
            broadcast_flag: 0,
            ciaddr: {0, 0, 0, 0},
            yiaddr: {0, 0, 0, 0},
            siaddr: {0, 0, 0, 0},
            giaddr: {0, 0, 0, 0},
            chaddr: [0, 0, 0, 0, 0, 0],
            options: []

  @type t :: %__MODULE__{
          op: integer(),
          htype: integer(),
          hops: integer(),
          xid: integer(),
          secs: integer(),
          broadcast_flag: integer(),
          ciaddr: :inet.ip4_address(),
          yiaddr: :inet.ip4_address(),
          siaddr: :inet.ip4_address(),
          giaddr: :inet.ip4_address(),
          chaddr: [byte()],
          options: Keyword.t()
        }

  @doc """
  Create a response to a request with some fields filled in.

  See RFC 2131 Table 3 for requirements. The caller is responsible for
  most of the fields.
  """
  @spec response(t()) :: t()
  def response(request = %__MODULE__{}) do
    %__MODULE__{
      op: @bootreply,
      htype: request.htype,
      hops: 0,
      xid: request.xid,
      secs: 0,
      broadcast_flag: request.broadcast_flag,
      giaddr: request.giaddr,
      chaddr: request.chaddr
    }
  end

  @doc """
  Decode the contents of a UDP packet
  """
  @spec decode(binary()) :: {:error, any()} | t()
  def decode(
        <<op, htype, _hlen, hops, xid::size(32), secs::size(16), broadcast_flag::size(1),
          0::size(15), ciaddr::binary-size(4), yiaddr::binary-size(4), siaddr::binary-size(4),
          giaddr::binary-size(4), chaddr::binary-size(6), 0::size(80), _sname::binary-size(64),
          _file::binary-size(128), @magic_cookie, options::binary>>
      ) do
    %__MODULE__{
      op: op,
      htype: htype,
      hops: hops,
      xid: xid,
      secs: secs,
      broadcast_flag: broadcast_flag,
      ciaddr: decode_ip(ciaddr),
      yiaddr: decode_ip(yiaddr),
      siaddr: decode_ip(siaddr),
      giaddr: decode_ip(giaddr),
      chaddr: decode_hwaddr(chaddr),
      options: Options.decode(options)
    }
  end

  def decode(_), do: {:error, :not_dhcp}

  @doc """
  Encode a message so that it can be put in a UDP packet
  """
  @spec encode(t()) :: binary()
  def encode(message = %__MODULE__{}) do
    options = Options.encode(message.options)
    ciaddr = encode_ip_raw(message.ciaddr)
    yiaddr = encode_ip_raw(message.yiaddr)
    siaddr = encode_ip_raw(message.siaddr)
    giaddr = encode_ip_raw(message.giaddr)
    hlen = Enum.count(message.chaddr)
    chaddr = encode_hwaddr_raw(message.chaddr)

    <<message.op, message.htype, hlen, message.hops, message.xid::size(32),
      message.secs::size(16), message.broadcast_flag::size(1), 0::size(15),
      ciaddr::binary-size(4), yiaddr::binary-size(4), siaddr::binary-size(4),
      giaddr::binary-size(4), chaddr::binary-size(6), 0::size(80), 0::unit(8)-size(192),
      @magic_cookie, options::binary>>
  end
end
