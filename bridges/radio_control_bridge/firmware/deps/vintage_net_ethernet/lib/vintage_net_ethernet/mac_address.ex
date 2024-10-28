defmodule VintageNetEthernet.MacAddress do
  @moduledoc """
  MAC Address utilities
  """

  @typedoc """
  A MAC address is a string of the form "aa:bb:cc:dd:ee:ff"
  """
  @type t() :: <<_::136>>

  @doc """
  Return true if this is a valid MAC address
  """
  @spec valid?(any()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def valid?(<<a, b, ?:, c, d, ?:, e, f, ?:, g, h, ?:, i, j, ?:, k, l>>) do
    valid_hex?(a) and
      valid_hex?(b) and
      valid_hex?(c) and
      valid_hex?(d) and
      valid_hex?(e) and
      valid_hex?(f) and
      valid_hex?(g) and
      valid_hex?(h) and
      valid_hex?(i) and
      valid_hex?(j) and
      valid_hex?(k) and
      valid_hex?(l)
  end

  def valid?(_), do: false

  defp valid_hex?(a)
       when a in [
              ?0,
              ?1,
              ?2,
              ?3,
              ?4,
              ?5,
              ?6,
              ?7,
              ?8,
              ?9,
              ?a,
              ?A,
              ?b,
              ?B,
              ?c,
              ?C,
              ?d,
              ?D,
              ?e,
              ?E,
              ?f,
              ?F
            ],
       do: true

  defp valid_hex?(_), do: false
end
