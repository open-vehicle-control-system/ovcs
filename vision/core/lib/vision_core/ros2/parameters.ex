defmodule VisionCore.Ros2.Parameters do
  @moduledoc """
  The vision parameters as the vision core node's ROS 2 parameters: the six
  `rcl_interfaces` services under `/<node_name>/`, so `ros2 param` and
  Foxglove's Parameters panel list, describe and change them.

  Every request is answered from `VisionCore.Parameters`. A ROS name is the
  parameter's id (`stereo.match.p1`). A set request is a
  `VisionCore.Parameters.set/3`, an unsaved change; saving is not exposed. A
  set request is answered per parameter; the atomic variant is refused.

  A description is read-only for a parameter fixed in the build, carries the
  range of a numeric range constraint, and gives in its constraints, separated
  by `; `, the accepted values (`one of: <a>, <b>`), the parameter it must stay
  above, the automatic mode setting it, and its default when it can be set back.

  Options: `:registry`, the registry answering (`VisionCore.Parameters`).
  """

  use GenServer
  require Logger

  alias Ros2Zenoh.RclInterfaces.Parameters, as: Codec
  alias VisionCore.Parameters.Parameter
  alias VisionCore.Ros2.ZenohClient

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    node_name = ZenohClient.node_name()

    services =
      Map.new(Codec.services(), fn {service, module} ->
        name = "/#{node_name}/#{service}"
        :ok = ZenohClient.register_service(name, module, self())
        {name, service}
      end)

    {:ok, %{services: services, registry: Keyword.get(opts, :registry, VisionCore.Parameters)}}
  end

  @impl GenServer
  def handle_info(
        {:service_request, %{service_name: service, query: query, request_payload: payload}},
        state
      ) do
    ZenohClient.respond(service, query, respond(state.services[service], payload, state.registry))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec respond(String.t(), binary(), GenServer.server()) :: binary()
  def respond("list_parameters", _payload, registry) do
    registry
    |> call(&VisionCore.Parameters.groups/1, [])
    |> Enum.flat_map(& &1.parameters)
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Codec.encode_list()
  end

  def respond("get_parameters", payload, registry) do
    payload
    |> Codec.decode_names()
    |> Enum.map(&(registry |> find(&1) |> ros_value()))
    |> Codec.encode_values()
  end

  def respond("get_parameter_types", payload, registry) do
    payload
    |> Codec.decode_names()
    |> Enum.map(fn name ->
      case find(registry, name) do
        %Parameter{type: type} -> type
        nil -> :not_set
      end
    end)
    |> Codec.encode_types()
  end

  def respond("describe_parameters", payload, registry) do
    payload
    |> Codec.decode_names()
    |> Enum.map(fn name ->
      case find(registry, name) do
        %Parameter{} = parameter -> describe(parameter)
        nil -> %{name: name, type: :not_set}
      end
    end)
    |> Codec.encode_descriptors()
  end

  def respond("set_parameters", payload, registry) do
    payload
    |> Codec.decode_parameters()
    |> Enum.map(fn {name, value} ->
      case call(registry, &VisionCore.Parameters.set(&1, name, value), {:error, "not applied"}) do
        {:ok, _parameter} ->
          :ok

        {:error, reason} = error ->
          Logger.info("#{__MODULE__}: #{name} = #{inspect(value)} refused: #{reason}")
          error
      end
    end)
    |> Codec.encode_results()
  end

  def respond("set_parameters_atomically", _payload, _registry),
    do:
      Codec.encode_result(
        {:error, "atomic sets are not supported; set the parameters one by one"}
      )

  @doc false
  @spec describe(Parameter.t()) :: map()
  def describe(%Parameter{} = parameter) do
    constraints =
      [
        choices(parameter.constraint),
        parameter.greater_than && "above #{parameter.greater_than}",
        automatic_controller(parameter.applies),
        settable_default(parameter)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    %{
      name: parameter.id,
      type: parameter.type,
      description: parameter.description || "",
      read_only: parameter.applies == :build,
      constraints: constraints
    }
    |> put_range(parameter)
  end

  @doc false
  @spec ros_value(Parameter.t() | nil) :: {VisionCore.Parameters.type(), term()} | nil
  def ros_value(%Parameter{value: value, type: type}) when not is_nil(value),
    do: {type, ros_term(type, value)}

  def ros_value(_parameter), do: nil

  defp ros_term(:double, value), do: value * 1.0
  defp ros_term(_type, value), do: value

  defp choices(%{kind: :choices, values: values}),
    do: "one of: " <> Enum.map_join(values, ", ", &to_string/1)

  defp choices(_constraint), do: nil

  defp automatic_controller({:auto, controller}), do: "set by #{controller} while it is on"
  defp automatic_controller(_applies), do: nil

  # A default the constraint refuses (libcamera's "auto") cannot be set back.
  defp settable_default(%Parameter{applies: :build}), do: nil
  defp settable_default(%Parameter{default: nil}), do: nil

  defp settable_default(%Parameter{default: default, constraint: constraint}) do
    if accepts?(constraint, default), do: "default: #{default}"
  end

  defp accepts?(%{kind: :choices, values: values}, value), do: value in values

  defp accepts?(%{kind: :range, min: min, max: max}, value),
    do: is_number(value) and value >= min and value <= max

  defp accepts?(_constraint, _value), do: true

  defp put_range(description, %Parameter{
         type: :integer,
         constraint: %{kind: :range, min: min, max: max}
       }),
       do: Map.put(description, :range, {min, max})

  defp put_range(description, %Parameter{
         type: :double,
         constraint: %{kind: :range, min: min, max: max}
       }),
       do: Map.put(description, :range, {min * 1.0, max * 1.0})

  defp put_range(description, _parameter), do: description

  defp find(registry, name) do
    case call(registry, &VisionCore.Parameters.get(&1, name), {:error, :not_found}) do
      {:ok, parameter} -> parameter
      {:error, _reason} -> nil
    end
  end

  # A busy or stopped registry answers as one with nothing, so this process keeps serving.
  defp call(registry, request, fallback) do
    request.(registry)
  catch
    :exit, reason ->
      Logger.warning("#{__MODULE__}: vision parameters unavailable: #{inspect(reason)}")
      fallback
  end
end
