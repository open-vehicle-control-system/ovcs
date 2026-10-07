defmodule Ros2.RclInterfaces.Parameters do
  @moduledoc """
  The `rcl_interfaces` parameter services and the messages they carry,
  for a node that serves its parameters (`RosBridge.Parameters`).

  Values are Elixir terms: a boolean, an integer, a float or a string.
  Array parameters are not supported: they decode as `{:unsupported,
  type}` and encode as not set.
  """

  import Ros2.Cdr

  # Type hashes from Lyrical's share/rcl_interfaces/srv/*.json.
  @services [
    {"list_parameters", "ListParameters",
     "RIHS01_3e6062bfbb27bfb8730d4cef2558221f51a11646d78e7bb30a1e83afac3aad9d"},
    {"get_parameters", "GetParameters",
     "RIHS01_bf9803d5c74cf989a5de3e0c2e99444599a627c7ff75f97b8c05b01003675cbc"},
    {"get_parameter_types", "GetParameterTypes",
     "RIHS01_da199c878688b3e530bdfe3ca8f74cb9fa0c303101e980a9e8f260e25e1c80ca"},
    {"describe_parameters", "DescribeParameters",
     "RIHS01_845b484d71eb0673dae682f2e3ba3c4851a65a3dcfb97bddd82c5b57e91e4cff"},
    {"set_parameters", "SetParameters",
     "RIHS01_56eed9a67e169f9cb6c1f987bc88f868c14a8fc9f743a263bc734c154015d7e0"},
    {"set_parameters_atomically", "SetParametersAtomically",
     "RIHS01_0e192ef259c07fc3c07a13191d27002222e65e00ccec653ca05e856f79285fcd"}
  ]

  for {_, name, hash} <- @services do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      def dds_type, do: unquote("rcl_interfaces::srv::dds_::#{name}_")
      def type_hash, do: unquote(hash)
    end
  end

  @doc """
  `{service, module}` for the six services a node serves its
  parameters on, `service` relative to the node's name. ROS clients
  wait for all six before calling any.
  """
  def services,
    do: for({service, name, _} <- @services, do: {service, Module.concat(__MODULE__, name)})

  @types %{not_set: 0, bool: 1, integer: 2, double: 3, string: 4}
  @type_ids Map.new(@types, fn {k, v} -> {v, k} end)

  @doc "The `ParameterType` code of a type."
  def type_id(type), do: Map.fetch!(@types, type)

  # ── requests ─────────────────────────────────────────────────

  @doc "The names in a get, get-types or describe request."
  def decode_names(payload) do
    {names, _} = read_sequence({payload, 0}, &read_string/1)
    names
  end

  @doc "The `{name, value}` pairs in a set or atomic set request."
  def decode_parameters(payload) do
    {parameters, _} =
      read_sequence({payload, 0}, fn input ->
        {name, input} = read_string(input)
        {value, input} = read_value(input)
        {{name, value}, input}
      end)

    parameters
  end

  defp read_value(input) do
    {type, input} = read_u8(input)
    {bool, input} = read_bool(input)
    {integer, input} = read_i64(input)
    {double, input} = read_f64(input)
    {string, input} = read_string(input)
    {_, input} = read_sequence(input, &read_u8/1)
    {_, input} = read_sequence(input, &read_bool/1)
    {_, input} = read_sequence(input, &read_i64/1)
    {_, input} = read_sequence(input, &read_f64/1)
    {_, input} = read_sequence(input, &read_string/1)

    value =
      case Map.get(@type_ids, type) do
        :bool -> bool
        :integer -> integer
        :double -> double
        :string -> string
        :not_set -> nil
        nil -> {:unsupported, type}
      end

    {value, input}
  end

  # ── responses ────────────────────────────────────────────────

  @doc "ListParameters response: the names, no prefixes."
  def encode_list(names), do: <<>> |> sequence(names, &string/2) |> sequence([], &string/2)

  @doc "GetParameters response: one `{type, value}` per name, `nil` when unknown."
  def encode_values(values), do: sequence(<<>>, values, &value/2)

  @doc "GetParameterTypes response: one type per name, `:not_set` when unknown."
  def encode_types(types), do: sequence(<<>>, types, &u8(&1, type_id(&2)))

  @doc """
  DescribeParameters response, from maps with `:name`, `:type`,
  `:description`, `:constraints`, `:read_only` and `:range`
  (`{low, high}`, absent when unbounded).
  """
  def encode_descriptors(descriptors), do: sequence(<<>>, descriptors, &descriptor/2)

  @doc "SetParameters response: `:ok` or `{:error, reason}` per parameter."
  def encode_results(results), do: sequence(<<>>, results, &result/2)

  @doc "SetParametersAtomically response."
  def encode_result(result), do: result(<<>>, result)

  defp value(acc, nil), do: value(acc, {:not_set, nil})

  defp value(acc, {type, v}) do
    acc
    |> u8(type_id(type))
    |> bool(type == :bool and v)
    |> i64(if type == :integer, do: v, else: 0)
    |> f64(if type == :double, do: v, else: 0.0)
    |> string(if type == :string, do: v, else: "")
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
  end

  defp descriptor(acc, d) do
    acc =
      acc
      |> string(d.name)
      |> u8(type_id(d.type))
      |> string(Map.get(d, :description, ""))
      |> string(Map.get(d, :constraints, ""))
      |> bool(Map.get(d, :read_only, false))
      |> bool(false)

    case {d.type, Map.get(d, :range)} do
      {:double, {low, high}} ->
        acc
        |> sequence([{low, high}], fn a, {l, h} -> a |> f64(l) |> f64(h) |> f64(0.0) end)
        |> sequence([], & &1)

      {:integer, {low, high}} ->
        acc
        |> sequence([], & &1)
        |> sequence([{low, high}], fn a, {l, h} -> a |> i64(l) |> i64(h) |> u64(1) end)

      _ ->
        acc |> sequence([], & &1) |> sequence([], & &1)
    end
  end

  defp result(acc, :ok), do: acc |> bool(true) |> string("")
  defp result(acc, {:error, reason}), do: acc |> bool(false) |> string(reason)
end
