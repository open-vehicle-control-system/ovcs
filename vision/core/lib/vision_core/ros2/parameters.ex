defmodule VisionCore.Ros2.Parameters do
  @moduledoc """
  The vision core node's ROS 2 parameters: the six `rcl_interfaces`
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

  A description's constraints carry the value declared, as `default:
  <value>` when it can be set again, and a string's accepted values, as
  `one of: <a>, <b>`, separated by `; `, so a viewer can offer to reset
  a parameter.
  """

  use GenServer
  require Logger

  alias Ros2Zenoh.RclInterfaces.Parameters, as: Codec
  alias VisionCore.Ros2.ZenohClient

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Declares the calling process's parameters, replacing any it declared before."
  def declare(parameters), do: GenServer.call(__MODULE__, {:declare, self(), parameters})

  @doc """
  Every parameter, sorted by name, with its value and constraints:
  `:name`, `:type`, `:value`, `:read_only`, and when declared
  `:description`, `:range` and `:values`.
  """
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Sets parameter `name` as a ROS set request would: `{:ok, value}` or `{:error, reason}`."
  @spec set_value(String.t(), term()) :: {:ok, term()} | {:error, String.t()}
  def set_value(name, value), do: GenServer.call(__MODULE__, {:set_value, name, value})

  @impl GenServer
  def init(_opts) do
    node_name = ZenohClient.node_name()

    services =
      Map.new(Codec.services(), fn {service, module} ->
        name = "/#{node_name}/#{service}"
        :ok = ZenohClient.register_service(name, module, self())
        {name, service}
      end)

    {:ok, %{services: services, parameters: %{}, owners: %{}}}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    listed =
      state.parameters
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(
        &Map.take(&1, [:name, :type, :value, :read_only, :description, :range, :values])
      )

    {:reply, listed, state}
  end

  def handle_call({:set_value, name, value}, _from, state) do
    case set(state.parameters[name], value) do
      {:ok, value} ->
        {:reply, {:ok, value},
         %{state | parameters: maybe_put_value(state.parameters, name, value)}}

      {:error, reason} = error ->
        {error, _parameters} = log_refusal(name, value, reason, error, state.parameters)
        {:reply, error, state}
    end
  end

  def handle_call({:declare, owner, parameters}, _from, state) do
    state = drop_owner(state, owner)
    monitor_reference = Process.monitor(owner)

    declared =
      Map.new(parameters, fn p ->
        {p.name,
         Map.merge(%{read_only: false}, p) |> Map.merge(%{owner: owner, default: p[:value]})}
      end)

    {:reply, :ok,
     %{
       state
       | parameters: Map.merge(state.parameters, declared),
         owners: Map.put(state.owners, owner, monitor_reference)
     }}
  end

  @impl GenServer
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
  Checks `value` against `parameter` and applies it with its `:set`;
  `{:ok, value}` with the value as stored, or `{:error, reason}`.
  """
  def set(nil, _value), do: {:error, "unknown parameter"}
  def set(%{read_only: true}, _value), do: {:error, "read-only: fixed at start"}

  def set(parameter, value) do
    with {:ok, value} <- check_type(parameter.type, value),
         :ok <- check_range(parameter, value),
         :ok <- check_values(parameter, value),
         :ok <- parameter.set.(value) do
      {:ok, value}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "not applied: #{inspect(reason)}"}
  end

  defp check_type(:bool, value) when is_boolean(value), do: {:ok, value}
  defp check_type(:integer, value) when is_integer(value), do: {:ok, value}
  defp check_type(:double, value) when is_number(value), do: {:ok, value * 1.0}
  defp check_type(:string, value) when is_binary(value), do: {:ok, value}
  defp check_type(type, value), do: {:error, "expected #{type}, got #{inspect(value)}"}

  defp check_range(%{range: {low, high}}, value) when value < low or value > high,
    do: {:error, "out of range #{low}..#{high}"}

  defp check_range(_parameter, _value), do: :ok

  defp check_values(%{values: values}, value) do
    if value in values, do: :ok, else: {:error, "expected one of #{Enum.join(values, ", ")}"}
  end

  defp check_values(_parameter, _value), do: :ok

  @doc false
  def describe(parameter) do
    constraints =
      [
        Map.get(parameter, :constraints, ""),
        if(resettable?(parameter), do: "default: #{parameter.default}"),
        if(parameter[:values], do: "one of: " <> Enum.join(parameter.values, ", "))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("; ")

    Map.take(parameter, [:name, :type, :description, :read_only, :range])
    |> Map.put(:constraints, constraints)
  end

  # A default outside the accepted values (libcamera's "auto") cannot be set back.
  defp resettable?(parameter) do
    not is_nil(parameter[:default]) and not Map.get(parameter, :read_only, false) and
      match?({:ok, _}, check_type(parameter.type, parameter.default)) and
      check_range(parameter, parameter.default) == :ok and
      check_values(parameter, parameter.default) == :ok
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

      {monitor_reference, owners} ->
        Process.demonitor(monitor_reference, [:flush])
        parameters = Map.reject(state.parameters, fn {_, p} -> p.owner == owner end)
        %{state | owners: owners, parameters: parameters}
    end
  end
end
