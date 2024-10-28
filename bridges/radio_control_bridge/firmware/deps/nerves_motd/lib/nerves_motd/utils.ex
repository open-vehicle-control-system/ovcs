defmodule NervesMOTD.Utils do
  @moduledoc false

  @doc """
  Extract IP addresses for one interface returned by `:inet.getifaddrs/0`

  ## Example:

      iex> if_addresses = [
      ...>   flags: [:up, :broadcast, :running, :multicast],
      ...>   addr: {10, 0, 0, 202},
      ...>   netmask: {255, 255, 255, 0},
      ...>   broadaddr: {10, 0, 0, 202},
      ...>   addr: {65152, 0, 0, 0, 47655, 60415, 65227, 8746},
      ...>   netmask: {65535, 65535, 65535, 65535, 0, 0, 0, 0},
      ...>   hwaddr: [184, 39, 235, 203, 34, 42]
      ...> ]
      iex> NervesMOTD.Utils.extract_ifaddr_addresses(if_addresses)
      [
        {{10, 0, 0, 202}, {255, 255, 255, 0}},
        {{65152, 0, 0, 0, 47655, 60415, 65227, 8746}, {65535, 65535, 65535, 65535, 0, 0, 0, 0}}
      ]
  """
  @spec extract_ifaddr_addresses(keyword()) :: [String.t()]
  def extract_ifaddr_addresses(kv_pairs, acc \\ [])

  def extract_ifaddr_addresses([], acc), do: Enum.reverse(acc)

  def extract_ifaddr_addresses([{:addr, addr}, {:netmask, netmask} | rest], acc) do
    extract_ifaddr_addresses(rest, [{addr, netmask} | acc])
  end

  def extract_ifaddr_addresses([_other | rest], acc) do
    extract_ifaddr_addresses(rest, acc)
  end

  @doc """
  Convert an IP address and subnet mask to a nice string

  Examples:

      iex> NervesMOTD.Utils.ip_address_mask_to_string({{10, 0, 0, 202}, {255, 255, 255, 0}})
      "10.0.0.202/24"
      iex> NervesMOTD.Utils.ip_address_mask_to_string({{65152, 0, 0, 0, 47655, 60415, 65227, 8746}, {65535, 65535, 65535, 65535, 0, 0, 0, 0}})
      "fe80::ba27:ebff:fecb:222a/64"

  """
  @spec ip_address_mask_to_string({:inet.ip_address(), :inet.ip_address()}) :: String.t()
  def ip_address_mask_to_string({address, mask}) do
    "#{:inet.ntoa(address)}/#{subnet_mask_to_prefix(mask)}"
  end

  @doc """
  Convert a subnet mask tuple to a prefix length

  Examples:

      iex> NervesMOTD.Utils.subnet_mask_to_prefix({255, 255, 255, 0})
      24

      iex> NervesMOTD.Utils.subnet_mask_to_prefix({65535, 65535, 65535, 65535, 0, 0, 0, 0})
      64
  """
  @spec subnet_mask_to_prefix(:inet.ip_address()) :: 0..128
  def subnet_mask_to_prefix(address) do
    address |> ip_to_binary() |> leading_ones(0)
  end

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_to_binary({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  defp leading_ones(<<0b11111111, rest::binary>>, sum), do: leading_ones(rest, sum + 8)
  defp leading_ones(<<0b11111110, _rest::binary>>, sum), do: sum + 7
  defp leading_ones(<<0b11111100, _rest::binary>>, sum), do: sum + 6
  defp leading_ones(<<0b11111000, _rest::binary>>, sum), do: sum + 5
  defp leading_ones(<<0b11110000, _rest::binary>>, sum), do: sum + 4
  defp leading_ones(<<0b11100000, _rest::binary>>, sum), do: sum + 3
  defp leading_ones(<<0b11000000, _rest::binary>>, sum), do: sum + 2
  defp leading_ones(<<0b10000000, _rest::binary>>, sum), do: sum + 1
  defp leading_ones(_, sum), do: sum

  @doc """
  Fit ansidata to a specified column width

  This function first trims the ansidata so that it doesn't exceed the specified
  width. Then if it's not long enough, it will pad the ansidata to either left or
  right justify it.

  ## Examples

      iex> s = [:red, "r", :yellow, "a", :light_yellow, "i", :green, "n", :blue, "b", :magenta, "o", :white, "w"]
      ...> NervesMOTD.Utils.fit_ansidata(s, 4)
      [:red, "r", :yellow, "a", :light_yellow, "i", :green, "n"]

      iex> s = [:red, "r", :yellow, "a", :light_yellow, "i", :green, "n", :blue, "b", :magenta, "o", :white, "w"]
      ...> NervesMOTD.Utils.fit_ansidata(s, 10)
      [[:red, "r", :yellow, "a", :light_yellow, "i", :green, "n", :blue, "b", :magenta, "o", :white, "w"], "   "]

      iex> NervesMOTD.Utils.fit_ansidata([:red, ["Hello"], [" ", "world!"]], 20, :right)
      ["        ", :red, "Hello", " ", "world!"]

      iex> NervesMOTD.Utils.fit_ansidata([:red, [["Hello"]], " ", "world!"], 2, :right)
      [:red, "He"]
  """
  @spec fit_ansidata(IO.ANSI.ansidata(), non_neg_integer(), :left | :right) :: IO.ANSI.ansidata()
  def fit_ansidata(ansidata, width, justification \\ :left) do
    {result, length_left} = trim_ansidata(ansidata, [], width)

    result
    |> Enum.reverse()
    |> add_padding(length_left, justification)
  end

  defp add_padding(ansidata, 0, _justification), do: ansidata
  defp add_padding(ansidata, count, :left), do: [ansidata, :binary.copy(" ", count)]
  defp add_padding(ansidata, count, :right), do: [:binary.copy(" ", count) | ansidata]

  defp trim_ansidata(_remainder, acc, 0), do: {acc, 0}
  defp trim_ansidata([], acc, length), do: {acc, length}
  defp trim_ansidata(char, acc, length) when is_integer(char), do: {[char | acc], length - 1}
  defp trim_ansidata(ansicode, acc, length) when is_atom(ansicode), do: {[ansicode | acc], length}

  defp trim_ansidata(str, acc, length) when is_binary(str) do
    sliced_string = String.slice(str, 0, length)
    {[sliced_string | acc], length - String.length(sliced_string)}
  end

  defp trim_ansidata([head | rest], acc, length) do
    {result, length_left} = trim_ansidata(head, acc, length)

    trim_ansidata(rest, result, length_left)
  end

  if Version.match?(System.version(), ">= 1.11.0") and Code.ensure_loaded?(NervesTimeZones) do
    # NervesTimeZones and Calendar.strftime require Elixir 1.11
    @spec formatted_local_time() :: binary()
    def formatted_local_time() do
      # NervesTimeZones is an optional dependency so make sure its started
      {:ok, _} = Application.ensure_all_started(:nerves_time_zones)

      NervesTimeZones.get_time_zone()
      |> DateTime.now!()
      |> DateTime.truncate(:second)
      |> Calendar.strftime("%c %Z")
    end
  else
    @spec formatted_local_time() :: binary()
    def formatted_local_time() do
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_string()
      |> Kernel.<>(" UTC")
    end
  end
end
