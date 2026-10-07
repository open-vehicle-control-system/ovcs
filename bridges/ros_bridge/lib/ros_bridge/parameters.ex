defmodule RosBridge.Parameters do
  @moduledoc """
  The bridge node's ROS 2 parameters: the six `rcl_interfaces`
  services under `/<node_name>/`, so `ros2 param` and Foxglove's
  Parameters panel list, describe and change them.

  Components declare their parameters with `declare/1`; they are
  removed when the declaring process exits, and declared again when it
  restarts. Each parameter is a map:

    * `:name` — dotted, e.g. `"stereo.left.lens_position"`
    * `:type` — `:bool`, `:integer`, `:double` or `:string`
    * `:value` — the value in force
    * `:description`, `:constraints` — free text for viewers
    * `:range` — `{low, high}` for numbers, checked before `:set`
    * `:values` — the accepted strings, checked before `:set`
    * `:read_only` — refused on set (settings fixed at start)
    * `:set` — `fn value -> :ok | {:error, reason} end`, run in this
      process, applying a value that passed the checks

  An integer is accepted for a `:double` parameter. A set request is
  answered per parameter; the atomic variant is refused.
  """

  use GenServer
  require Logger

  alias Ros2.RclInterfaces.Parameters, as: Codec
  alias RosBridge.ZenohClient

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Declares the calling process's parameters, replacing any it declared before."
  def declare(parameters), do: GenServer.call(__MODULE__, {:declare, self(), parameters})

  @impl true
  def init(_opts) do
    node = ZenohClient.node_name()

    services =
      Map.new(Codec.services(), fn {service, module} ->
        name = "/#{node}/#{service}"
        :ok = ZenohClient.register_service(name, module, self())
        {name, service}
      end)

    {:ok, %{services: services, parameters: %{}, owners: %{}}}
  end

  @impl true
  def handle_call({:declare, owner, parameters}, _from, state) do
    state = drop_owner(state, owner)
    ref = Process.monitor(owner)

    declared =
      Map.new(parameters, fn p ->
        {p.name, Map.merge(%{read_only: false}, p) |> Map.put(:owner, owner)}
      end)

    {:reply, :ok,
     %{
       state
       | parameters: Map.merge(state.parameters, declared),
         owners: Map.put(state.owners, owner, ref)
     }}
  end

  @impl true
  def handle_info(
        {:service_request, %{service_name: service, query: query, request_payload: payload}},
        state
      ) do
    {response, state} = handle_request(state.services[service], payload, state)
    ZenohClient.respond(service, query, response)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, state),
    do: {:noreply, drop_owner(state, owner)}

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_request("list_parameters", _payload, state),
    do: {Codec.encode_list(state.parameters |> Map.keys() |> Enum.sort()), state}

  defp handle_request("get_parameters", payload, state) do
    values =
      for name <- Codec.decode_names(payload) do
        case state.parameters[name] do
          %{value: value, type: type} when not is_nil(value) -> {type, value}
          _ -> nil
        end
      end

    {Codec.encode_values(values), state}
  end

  defp handle_request("get_parameter_types", payload, state) do
    types =
      for name <- Codec.decode_names(payload),
          do: get_in(state.parameters, [name, :type]) || :not_set

    {Codec.encode_types(types), state}
  end

  defp handle_request("describe_parameters", payload, state) do
    descriptors =
      for name <- Codec.decode_names(payload) do
        Map.get(state.parameters, name, %{name: name, type: :not_set}) |> describe()
      end

    {Codec.encode_descriptors(descriptors), state}
  end

  defp handle_request("set_parameters", payload, state) do
    {results, parameters} =
      Enum.map_reduce(Codec.decode_parameters(payload), state.parameters, fn {name, value},
                                                                             parameters ->
        case set(parameters[name], value) do
          {:ok, value} -> {:ok, maybe_put_value(parameters, name, value)}
          {:error, reason} = error -> log_refusal(name, value, reason, error, parameters)
        end
      end)

    {Codec.encode_results(results), %{state | parameters: parameters}}
  end

  defp handle_request("set_parameters_atomically", _payload, state),
    do:
      {Codec.encode_result(
         {:error, "atomic sets are not supported; set the parameters one by one"}
       ), state}

  defp log_refusal(name, value, reason, error, parameters) do
    Logger.warning("#{__MODULE__}: #{name} = #{inspect(value)} refused: #{reason}")
    {error, parameters}
  end

  @doc """
  Checks `value` against parameter `p` and applies it with its `:set`;
  `{:ok, value}` with the value as stored, or `{:error, reason}`.
  """
  def set(nil, _value), do: {:error, "unknown parameter"}
  def set(%{read_only: true}, _value), do: {:error, "read-only: fixed at start"}

  def set(p, value) do
    with {:ok, value} <- check_type(p.type, value),
         :ok <- check_range(p, value),
         :ok <- check_values(p, value),
         :ok <- p.set.(value) do
      {:ok, value}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "not applied: #{inspect(reason)}"}
  end

  defp check_type(:bool, v) when is_boolean(v), do: {:ok, v}
  defp check_type(:integer, v) when is_integer(v), do: {:ok, v}
  defp check_type(:double, v) when is_number(v), do: {:ok, v * 1.0}
  defp check_type(:string, v) when is_binary(v), do: {:ok, v}
  defp check_type(type, v), do: {:error, "expected #{type}, got #{inspect(v)}"}

  defp check_range(%{range: {low, high}}, v) when v < low or v > high,
    do: {:error, "out of range #{low}..#{high}"}

  defp check_range(_p, _v), do: :ok

  defp check_values(%{values: values}, v) do
    if v in values, do: :ok, else: {:error, "expected one of #{Enum.join(values, ", ")}"}
  end

  defp check_values(_p, _v), do: :ok

  defp describe(p) do
    constraints =
      case p do
        %{values: values} ->
          Enum.join([Map.get(p, :constraints, "") | ["one of: " <> Enum.join(values, ", ")]], " ")

        _ ->
          Map.get(p, :constraints, "")
      end

    Map.take(p, [:name, :type, :description, :read_only, :range])
    |> Map.put(:constraints, String.trim(constraints))
  end

  defp maybe_put_value(parameters, name, value) do
    if Map.has_key?(parameters, name),
      do: put_in(parameters, [name, :value], value),
      else: parameters
  end

  defp drop_owner(state, owner) do
    case Map.pop(state.owners, owner) do
      {nil, _} ->
        state

      {ref, owners} ->
        Process.demonitor(ref, [:flush])
        parameters = Map.reject(state.parameters, fn {_, p} -> p.owner == owner end)
        %{state | owners: owners, parameters: parameters}
    end
  end
end
