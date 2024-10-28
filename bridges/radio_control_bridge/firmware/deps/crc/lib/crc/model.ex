defmodule CRC.Model do

  @type t() :: %__MODULE__{
    bits: 0x00..0xff,
    sick: boolean(),
    width: 0x00..0xff,
    poly: 0x0000000000000000..0xffffffffffffffff,
    init: 0x0000000000000000..0xffffffffffffffff,
    refin: boolean(),
    refout: boolean(),
    xorout: 0x0000000000000000..0xffffffffffffffff,
    check: 0x0000000000000000..0xffffffffffffffff,
    residue: 0x0000000000000000..0xffffffffffffffff,
    name: binary,
    key: atom(),
    aliases: %{
      optional(atom()) => binary
    },
    slow: boolean(),
    value: non_neg_integer()
  }

  defstruct [
    bits: nil,
    sick: nil,
    width: nil,
    poly: nil,
    init: nil,
    refin: nil,
    refout: nil,
    xorout: nil,
    check: nil,
    residue: nil,
    name: nil,
    key: nil,
    aliases: %{},
    slow: false,
    value: 0
  ]

  def decode(binary) when is_binary(binary) do
    parse(binary, %__MODULE__{})
  end

  def decode_file(filename) do
    with {:ok, content} <- :file.read_file(filename) do
      decode_list(content)
    end
  end

  def decode_list(binary) when is_binary(binary) do
    decode_list(binary, [])
  end

  def dump_code(model_or_models) do
    IO.puts(gen_code(model_or_models))
  end

  def gen_code(model = %__MODULE__{}) do
    [
      gen_stubs(model),
      "\n",
      gen_tables(model)
    ]
  end
  def gen_code(models = [%__MODULE__{} | _]) do
    stubs =
      for model <- models, into: [] do
        {model.width, model.key, gen_stubs(model)}
      end
      |> :lists.usort()
    tables =
      for model <- models, into: [] do
        {model.width, model.key, gen_tables(model)}
      end
      |> :lists.usort()
    stubs = for {_, _, stub} <- stubs, into: [], do: stub
    tables = for {_, _, table} <- tables, into: [], do: table
    [
      stubs,
      "\n",
      tables
    ]
  end

  def gen_stubs(%__MODULE__{ aliases: aliases, name: name, key: root_key }) do
    entries = [
      {root_key, "{{NULL, NULL}, false, 0, \"#{root_key}\", 0, \"#{root_key}\", \"#{name}\"},\n"}
      | (for {key, val} <- aliases, into: [] do
        {key, "{{NULL, NULL}, false, 0, \"#{root_key}\", 0, \"#{key}\", \"#{val}\"},\n"}
      end)
    ]
    entries =
      for {_, entry} <- Enum.sort_by(entries, fn ({key, _}) -> key end), into: [] do
        entry
      end
    [
      "/* #{root_key} */\n"
      | entries
    ]
  end

  def gen_tables(model = %__MODULE__{ bits: bits }) do
    table =
      if model.sick do
        :lists.duplicate(256, 0)
      else
        context = :crc_nif.crc_init(model)
        {true, table} = :crc_nif.debug_table(context)
        table
      end
    [_ | table_values] = :lists.flatten(for n <- table, into: [] do
      [?,, encode_hex(n, bits)]
    end)
    width = "#{model.width}"
    poly = encode_hex(model.poly, bits)
    init = encode_hex(model.init, bits)
    refin = "#{model.refin}"
    refout = "#{model.refin}"
    xorout = encode_hex(model.xorout, bits)
    check = encode_hex(model.check, bits)
    residue = encode_hex(model.residue, bits)
    name = "\"#{model.name}\""
    aliases =
      if map_size(model.aliases) == 0 do
        []
      else
        for {_, val} <- model.aliases, into: [] do
          [?\s, "alias=\"", val, ?\"]
        end
      end
    [
      if model.sick do
        ["/* width=", width, " poly=", poly, " init=", init, " sick=true check=", check, " name=", name, aliases, " */\n"]
      else
        ["/* width=", width, " poly=", poly, " init=", init, " refin=", refin, " refout=", refout, " xorout=", xorout, " check=", check, " residue=", residue, " name=", name, aliases, " */\n"]
      end,
      "{{{NULL, NULL}, true, 0, \"#{model.key}\", #{bits}},\n",
      " #{model.sick},\n",
      " ", width, ",\n",
      " ", poly, ",\n",
      " ", init, ",\n",
      " ", refin, ",\n",
      " ", refout, ",\n",
      " ", xorout, ",\n",
      " ", check, ",\n",
      " ", residue, ",\n",
      " {", table_values, "}},\n"
    ]
  end

  @doc false
  defp decode_list(data, acc) do
    case decode(data) do
      {:ok, model, rest} ->
        decode_list(rest, [model | acc])
      {:error, _, <<>>} ->
        {:ok, :lists.reverse(acc)}
      {:error, model, rest} ->
        {:error, model, rest}
    end
  end

  @doc false
  defp parse("width=" <> rest, acc = %{ width: nil }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    value = :erlang.binary_to_integer(value)
    acc = %{ acc | width: value }
    parse(rest, acc)
  end
  defp parse("poly=" <> rest, acc = %{ poly: nil }) do
    {rest, "0x" <> value} = take_until_whitespace(rest, <<>>)
    value = decode_hex(value)
    acc = %{ acc | poly: value }
    parse(rest, acc)
  end
  defp parse("init=" <> rest, acc = %{ init: nil }) do
    {rest, "0x" <> value} = take_until_whitespace(rest, <<>>)
    value = decode_hex(value)
    acc = %{ acc | init: value }
    parse(rest, acc)
  end
  defp parse("xorout=" <> rest, acc = %{ xorout: nil }) do
    {rest, "0x" <> value} = take_until_whitespace(rest, <<>>)
    value = decode_hex(value)
    acc = %{ acc | xorout: value }
    parse(rest, acc)
  end
  defp parse("check=" <> rest, acc = %{ check: nil }) do
    {rest, "0x" <> value} = take_until_whitespace(rest, <<>>)
    value = decode_hex(value)
    acc = %{ acc | check: value }
    parse(rest, acc)
  end
  defp parse("residue=" <> rest, acc = %{ residue: nil }) do
    {rest, "0x" <> value} = take_until_whitespace(rest, <<>>)
    value = decode_hex(value)
    acc = %{ acc | residue: value }
    parse(rest, acc)
  end
  defp parse("refin=" <> rest, acc = %{ refin: nil }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    value =
      case :erlang.binary_to_atom(value, :unicode) do
        val when is_boolean(val) -> val
      end
    acc = %{ acc | refin: value }
    parse(rest, acc)
  end
  defp parse("refout=" <> rest, acc = %{ refout: nil }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    value =
      case :erlang.binary_to_atom(value, :unicode) do
        val when is_boolean(val) -> val
      end
    acc = %{ acc | refout: value }
    parse(rest, acc)
  end
  defp parse("sick=" <> rest, acc = %{ sick: nil }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    value =
      case :erlang.binary_to_atom(value, :unicode) do
        val when is_boolean(val) -> val
      end
    acc = %{ acc | sick: value }
    parse(rest, acc)
  end
  defp parse("name=" <> rest, acc = %{ name: nil }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    name = strip_quotes(value, <<>>)
    root_key = :erlang.binary_to_atom(underscore(value, <<>>), :unicode)
    acc = %{ acc | name: name, key: root_key }
    parse(rest, acc)
  end
  defp parse("alias=" <> rest, acc = %{ aliases: aliases }) do
    {rest, value} = take_until_whitespace(rest, <<>>)
    name = strip_quotes(value, <<>>)
    key = :erlang.binary_to_atom(underscore(value, <<>>), :unicode)
    aliases = Map.put(aliases, key, name)
    acc = %{ acc | aliases: aliases }
    parse(rest, acc)
  end
  defp parse(<< ?\n, rest :: binary >>, acc) do
    acc =
      if is_nil(acc.sick) do
        %{ acc | sick: false }
      else
        acc
      end
    if is_nil(acc.width) or is_nil(acc.refin) or is_nil(acc.poly) do
      {:error, acc, rest}
    else
      bits = (div(acc.width, 8) + (if rem(acc.width, 8) == 0, do: 0, else: 1)) * 8
      bits =
        case bits do
          _ when bits in [8, 16, 32, 64] -> bits
          _ when bits < 8 -> 8
          _ when bits > 8 and bits < 16 -> 16
          _ when bits > 16 and bits < 32 -> 32
          _ when bits > 32 and bits < 64 -> 64
        end
      acc = %{ acc | bits: bits }
      {:ok, acc, rest}
    end
  end
  defp parse(<< _, rest :: binary >>, acc) do
    parse(rest, acc)
  end
  defp parse(<<>>, acc) do
    parse(<< ?\n >>, acc)
  end

  @doc false
  defp decode_hex(value) do
    :erlang.binary_to_integer(value, 16)
  end

  @doc false
  defp encode_hex(value, bits) do
    "0x" <> Base.encode16(<< value :: unsigned-big-integer-unit(1)-size(bits) >>, case: :lower)
  end

  @doc false
  defp take_until_whitespace(<<>>, acc) do
    {<<>>, acc}
  end
  defp take_until_whitespace(rest = << ?\n, _ :: binary >>, acc) do
    {rest, acc}
  end
  defp take_until_whitespace(<< ?\s, rest :: binary >>, acc) do
    {rest, acc}
  end
  defp take_until_whitespace(<< c, rest :: binary >>, acc) do
    take_until_whitespace(rest, << acc ::binary, c >>)
  end

  @doc false
  defp underscore(<< ?", rest :: binary >>, acc) do
    underscore(rest, acc)
  end
  defp underscore(<< c, rest :: binary >>, acc) when c in ?A..?Z do
    underscore(rest, << acc :: binary, (c + 32) >>)
  end
  defp underscore(<< c, rest :: binary >>, acc) when c in ?a..?z or c in ?0..?9 do
    underscore(rest, << acc :: binary, c >>)
  end
  defp underscore(<< c, rest :: binary >>, acc) when c in [?-, ?/] do
    underscore(rest, << acc :: binary, ?_ >>)
  end
  defp underscore(<<>>, acc) do
    acc
  end

  @doc false
  defp strip_quotes(<< ?", rest :: binary >>, acc) do
    strip_quotes(rest, acc)
  end
  defp strip_quotes(<< c, rest :: binary >>, acc) do
    strip_quotes(rest, << acc :: binary, c >>)
  end
  defp strip_quotes(<<>>, acc) do
    acc
  end

end
