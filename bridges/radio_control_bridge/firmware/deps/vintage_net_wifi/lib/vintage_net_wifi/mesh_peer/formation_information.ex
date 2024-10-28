defmodule VintageNetWiFi.MeshPeer.FormationInformation do
  @moduledoc """
  * `connected_to_as`:
    true if the Authentication Protocol Identifier is set to 2.
    (indicating IEEE 802.1X authentication) and the station has an
    active connection to an AS
  * `number_of_peerings`:
    indicates the mnumber of mesh peerings currently maintained
    but the station or 63, whichever is smaller
  * `connected_to_mesh_gate`:
    true if the station has a mesh path to the mesh gate that announces
    it's presence using GANN, RANN or PREQ elements
  """
  alias VintageNetWiFi.Utils
  defstruct [:connected_to_as, :number_of_peerings, :connected_to_mesh_gate]

  @type t() :: %__MODULE__{
          connected_to_as: boolean(),
          number_of_peerings: 0..63,
          connected_to_mesh_gate: boolean()
        }

  @spec decode_formation_information(<<_::8>>) :: t()
  def decode_formation_information(<<
        connected_to_as::1,
        number_of_peerings::6,
        connected_to_mesh_gate::1
      >>) do
    %__MODULE__{
      connected_to_as: Utils.bit_to_boolean(connected_to_as),
      number_of_peerings: number_of_peerings,
      connected_to_mesh_gate: Utils.bit_to_boolean(connected_to_mesh_gate)
    }
  end
end
