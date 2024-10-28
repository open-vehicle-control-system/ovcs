defmodule CRC do
  @moduledoc """
  This module is used to calculate CRC (Cyclic Redundancy Check) values
  for binary data. It uses NIF functions written in C to iterate over
  the given binary calculating the CRC checksum value.

  CRC implementations have been tested against these online calculators to
  validate their correctness to the best of our ability.

  https://www.lammertbies.nl/comm/info/crc-calculation.html
  http://www.sunshine2k.de/coding/javascript/crc/crc_js.html
  """

  @doc """
  Calculate a CRC checksum for the `input` based on the crc `params` given.

  `params` can be an atom for one of the compiled models. See `CRC.list/0` for
  a full list or a Map with parameters to create a model at runtime. The map
  given should have all of the following keys:

  `width` - (unsigned integer) representation for the width of the CRC in bits
  `poly` - (unsigned integer) the polynomial used for the CRC calculation
  `init` - (unsigned integer) The initial value used when starting the calculation
  `refin` - (boolean) if the input value should be reflected. This is used for changing between endian's
  `refout` - (boolean) if the outvalue should be reflected when calculation is completed
  `xorout` - (unsigned integer) Final xor value used when completing the CRC calculation

  ## Examples

      %{
        width: 16,
        poly: 0x1021,
        init: 0x00,
        refin: false,
        refout: false,
        xorout: 0x00
      }

  You can also extend one of the compiled models at runtime by creating a map
  with `extend` key set to the model you wish to extend and the keys you wish
  to override for that model.

  For example to override the initial value for the `:crc_16_ccitt_false` model
  to `0x1D0F` you would pass the following Map as params:

      `%{extend: :crc_16_ccitt_false, init: 0x1D0F}`

  You can learn more about CRC calculation here:
  https://www.sunshine2k.de/articles/coding/crc/understanding_crc.html
  """
  @spec crc(:crc_algorithm.params(), iodata()) :: :crc_algorithm.value()
  defdelegate crc(params, input), to: :crc

  @doc """
  Initialize a resource to be used for doing CRC calculations. The returned
  resource can be used with `crc/2` or `crc_update/2` to calculate CRC checksums.

  Resource is created using the same `params` types that are used with `crc/2`:

    - atom's for compiled models
    - Map with model values
    - Map to extend a compiled model.

  If used with `crc/2` the returned resource can be re-used multiple times, but
  using a map or atom for a compiled model will likely be slightly more
  performant.

  When using with `crc_update/2` a new resource will be returned with every
  call that should be used to continue the calculation.
  """
  @spec crc_init(:crc_algorithm.params()) :: :crc_algorithm.resource()
  defdelegate crc_init(params), to: :crc

  @doc """
  Begins or continues a multi-part CRC calculation.

  Takes a `resource` from result of `crc_init/1` or previous `crc_update/2`
  call, and binary `input`, returns a new `resource` to be used to continue or
  finalize the CRC calculation.
  """
  @spec crc_update(:crc_algorithm.resource(), iodata()) :: :crc_algorithm.resource()
  defdelegate crc_update(resource, input), to: :crc

  @doc """
  Takes a `resource` result from `crc_update/2` and finalizes the multi-part
  CRC calculation.
  """
  @spec crc_final(:crc_algorithm.resource()) :: :crc_algorithm.value()
  defdelegate crc_final(resource), to: :crc

  @doc """
  Calculate a CRC checksum for the `input` based on the crc `params` given.

  See `CRC.crc/2` for details on valid `params`.

  This function has the parameter order reversed to allow easier use with pipelines.
  allowing code to be written like:

  ## Examples

      read_data() |> CRC.calculate(:crc_16) |> do_something()

  """
  @spec calculate(iodata(), :crc_algorithm.params()) :: :crc_algorithm.value()
  def calculate(input, params) do
    :crc.crc(params, input)
  end

  @doc """
  Returns a list of all the compiled CRC models.
  """
  @spec list() :: [{atom, String.t}]
  def list() do
    :crc_nif.crc_list()
    |> Map.to_list()
    |> Enum.map(fn {model, map} -> {model, Map.get(map, model)} end)
  end

  @doc """
  Returns a list of all compiled CRC Models that match the filter given.

  Filter is compiled into a regular expression and matched against the model name
  and description.
  """
  @spec list(binary) :: [{atom, String.t}]
  def list(filter) do
    list()
    |> Enum.filter(&(list_filter(&1, filter)))
  end

  defp list_filter({model_atom, model_name}, filter) do
    atom_string = Atom.to_string(model_atom)

    {:ok, rfilter} = Regex.compile(filter)
    Regex.match?(rfilter, atom_string) or Regex.match?(rfilter, model_name)
  end

  use CRC.Legacy
end
