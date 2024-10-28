defmodule VintageNetWiFi.MeshPeer.Capabilities do
  @moduledoc """
  Capabilities supported by a mesh node

  * `power_slave_level`:
    true if at least one of the peer-specific mesh
    power management modes is deep sleep mode
  * `tbtt_adjusting`:
    true while the TBBT adjustment procedure is ongoing.
  * `mbca_enabled`:
    true if the station is using MBCA
  * `forwarding`:
    true if the station forwards MSDUs
  * `mcca_enabled`:
    true if the station uses MCCA
  * `mcca_supported`:
    true if the station implements MCCA
  """
  alias VintageNetWiFi.Utils

  @type t() :: %__MODULE__{
          power_slave_level: boolean(),
          tbtt_adjusting: boolean(),
          mbca_enabled: boolean(),
          forwarding: boolean(),
          mcca_enabled: boolean(),
          mcca_supported: boolean(),
          accepting_peerings: boolean()
        }

  defstruct [
    :power_slave_level,
    :tbtt_adjusting,
    :mbca_enabled,
    :forwarding,
    :mcca_enabled,
    :mcca_supported,
    :accepting_peerings
  ]

  @spec decode_capabilities(<<_::8>>) :: t()
  def decode_capabilities(<<
        _reserved::1,
        power_slave_level::1,
        tbtt_adjusting::1,
        mbca_enabled::1,
        forwarding::1,
        mcca_enabled::1,
        mcca_supported::1,
        accepting_peerings::1
      >>) do
    %__MODULE__{
      power_slave_level: Utils.bit_to_boolean(power_slave_level),
      tbtt_adjusting: Utils.bit_to_boolean(tbtt_adjusting),
      mbca_enabled: Utils.bit_to_boolean(mbca_enabled),
      forwarding: Utils.bit_to_boolean(forwarding),
      mcca_enabled: Utils.bit_to_boolean(mcca_enabled),
      mcca_supported: Utils.bit_to_boolean(mcca_supported),
      accepting_peerings: Utils.bit_to_boolean(accepting_peerings)
    }
  end
end
