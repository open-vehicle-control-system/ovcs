defmodule VintageNetWiFi.SignalInfo do
  @moduledoc """
  Information about active connection signal levels

  * `:center_frequency1` - center frequency for the first segment
  * `:center_frequency2` - center frequency for the second segment (if relevant)
  * `:frequency` - control frequency
  * `:linkspeed` - current TX rate
  * `:signal_dbm` - current signal in dBm (RSSI)
  * `:signal_percent` - signal quality in percent
  * `:width` - channel width
  """
  alias VintageNetWiFi.Utils

  defstruct [
    :center_frequency1,
    :center_frequency2,
    :frequency,
    :linkspeed,
    :signal_dbm,
    :signal_percent,
    :width
  ]

  @type t :: %__MODULE__{
          center_frequency1: non_neg_integer(),
          center_frequency2: non_neg_integer(),
          frequency: non_neg_integer(),
          linkspeed: non_neg_integer(),
          signal_dbm: integer(),
          signal_percent: 0..100,
          width: String.t()
        }

  @doc """
  Create a new SignalInfo struct
  """
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          String.t()
        ) ::
          VintageNetWiFi.SignalInfo.t()
  def new(center_frequency1, center_frequency2, frequency, linkspeed, signal_dbm, width) do
    info = Utils.frequency_info(frequency)

    %__MODULE__{
      center_frequency1: center_frequency1,
      center_frequency2: center_frequency2,
      frequency: frequency,
      linkspeed: linkspeed,
      signal_dbm: signal_dbm,
      signal_percent: info.dbm_to_percent.(signal_dbm),
      width: width
    }
  end
end
