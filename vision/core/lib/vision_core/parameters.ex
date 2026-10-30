defmodule VisionCore.Parameters do
  @moduledoc """
  The vision unit's parameters: the settings of its components and pipeline
  stages, with what each accepts, when it applies and whether it differs from
  its saved value or built-in default.

  The process owning a component or stage declares its groups with
  `declare/2`, giving each parameter a `get` and a `set` function run in this
  process. `get` is read on every listing, so the value listed is the one in
  use. A parameter with `applies: {:auto, controller}` is set by that
  controller's automatic mode while the controller is `true`.

  Groups go when their owner exits. Values set through `set/3` are kept and
  set again when a restarted owner declares its groups.

  ROS 2 and the API are adapters reading and setting parameters here.
  """
  use GenServer
  require Logger

  alias VisionCore.Parameters.{Group, Parameter, Store}

  @type id :: String.t()
  @type type :: :integer | :double | :bool | :string
  @type constraint ::
          %{kind: :range, min: number(), max: number(), step: number() | nil}
          | %{kind: :choices, values: [term()]}
          | %{kind: :bool}
  @type applies :: :live | :build | {:auto, controller :: id()}
  @type state :: :builtin | :saved | :unsaved | :automatic
  @type declaration :: %{
          required(:name) => String.t(),
          required(:type) => type(),
          required(:get) => (-> term()),
          optional(:set) => (term() -> :ok | {:error, String.t()}),
          optional(:constraint) => constraint(),
          optional(:applies) => applies(),
          optional(:greater_than) => String.t(),
          optional(:description) => String.t(),
          optional(:export) => [atom()]
        }
  @type group_declaration :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:summary) => String.t(),
          required(:kind) => :component | :stage,
          required(:placement) => :flow | :side,
          required(:position) => non_neg_integer(),
          optional(:status) => (-> {:ok | :warning | :off, String.t()} | nil),
          required(:parameters) => [declaration()]
        }

  @parameter_fields [:id, :group, :name, :type, :constraint, :applies, :greater_than] ++
                      [:description, :export]

  @doc """
  Starts the registry. Options: `:store`, the module holding saved values
  (`VisionCore.Parameters.Store`), and `:name` (`VisionCore.Parameters`).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Declares the calling process's groups, replacing those it declared before.
  Answers before reading or setting any value, so an owner may declare from
  its own `init/1`.
  """
  @spec declare(GenServer.server(), [group_declaration()]) :: :ok
  def declare(server \\ __MODULE__, groups), do: GenServer.call(server, {:declare, groups})

  @doc "Every group, by position, with its parameters in declared order."
  @spec groups(GenServer.server()) :: [Group.t()]
  def groups(server \\ __MODULE__), do: GenServer.call(server, :groups)

  @doc "The parameter `id`."
  @spec get(GenServer.server(), id()) :: {:ok, Parameter.t()} | {:error, :not_found}
  def get(server \\ __MODULE__, id), do: GenServer.call(server, {:get, id})

  @doc """
  Checks `value` against parameter `id` and applies it. Switching an automatic
  mode off first sets each parameter it controls to the value it left.
  """
  @spec set(GenServer.server(), id(), term()) :: {:ok, Parameter.t()} | {:error, String.t()}
  def set(server \\ __MODULE__, id, value), do: GenServer.call(server, {:set, id, value})

  @doc "The number of parameters whose value differs from their saved value or default."
  @spec unsaved_count(GenServer.server()) :: non_neg_integer()
  def unsaved_count(server \\ __MODULE__), do: GenServer.call(server, :unsaved_count)

  @impl GenServer
  def init(opts) do
    store = Keyword.get(opts, :store, Store)

    {:ok,
     %{store: store, saved: store.load(), groups: %{}, owners: %{}, defaults: %{}, changed: %{}}}
  end

  @impl GenServer
  def handle_call({:declare, groups}, {owner, _tag}, state) do
    state = drop_owner(state, owner)

    state = %{
      state
      | groups: Map.put(state.groups, owner, Enum.map(groups, &normalize_group/1)),
        owners: Map.put(state.owners, owner, Process.monitor(owner))
    }

    {:reply, :ok, state, {:continue, {:apply, owner}}}
  end

  def handle_call(:groups, _from, state) do
    {values, state} = read_values(state, Enum.map(all_parameters(state), & &1.id))

    groups =
      state
      |> sorted_groups()
      |> Enum.map(&to_group(&1, values, state))

    {:reply, groups, state}
  end

  def handle_call({:get, id}, _from, state) do
    case find(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      declared ->
        {parameter, state} = read_parameter(state, declared)
        {:reply, {:ok, parameter}, state}
    end
  end

  def handle_call({:set, id, value}, _from, state) do
    case find(state, id) do
      nil -> refuse(id, value, "unknown parameter", state)
      declared -> set_declared(state, declared, value)
    end
  end

  def handle_call(:unsaved_count, _from, state) do
    parameters = all_parameters(state)
    {values, state} = read_values(state, Enum.map(parameters, & &1.id))
    count = Enum.count(parameters, &(parameter_state(&1, values, state) == :unsaved))
    {:reply, count, state}
  end

  @impl GenServer
  def handle_continue({:apply, owner}, state) do
    declared = state.groups |> Map.get(owner, []) |> Enum.flat_map(& &1.parameters)
    {_values, state} = read_values(state, Enum.map(declared, & &1.id))
    controllers = MapSet.new(all_parameters(state), &controller/1)

    declared
    |> Enum.filter(&(&1.applies != :build and Map.has_key?(state.changed, &1.id)))
    |> Enum.sort_by(&(not MapSet.member?(controllers, &1.id)))
    |> Enum.each(&apply_changed(state, &1))

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _reference, :process, owner, _reason}, state),
    do: {:noreply, drop_owner(state, owner)}

  def handle_info(_message, state), do: {:noreply, state}

  defp set_declared(state, declared, value) do
    {values, state} = read_values(state, related_ids(state, declared))

    case apply_value(state, declared, value, values) do
      {:ok, applied} ->
        state = %{state | changed: Map.merge(state.changed, applied)}
        {parameter, state} = read_parameter(state, declared)
        {:reply, {:ok, parameter}, state}

      {:error, reason} ->
        refuse(declared.id, value, reason, state)
    end
  end

  defp refuse(id, value, reason, state) do
    Logger.warning("vision parameter #{id} = #{inspect(value)} refused: #{reason}")
    {:reply, {:error, reason}, state}
  end

  # The values applied by id, or the first refusal.
  defp apply_value(state, declared, value, values) do
    with :ok <- check_settable(declared, values),
         {:ok, value} <- check_type(declared.type, value),
         :ok <- check_constraint(declared.constraint, value),
         :ok <- check_order(state, declared, value, values),
         {:ok, released} <- release_controlled(state, declared, value, values),
         :ok <- call_set(declared, value) do
      {:ok, Map.put(released, declared.id, value)}
    end
  end

  defp check_settable(%{applies: :build}, _values), do: {:error, "fixed in the build"}

  defp check_settable(declared, values) do
    if automatic?(declared, values),
      do: {:error, "set by #{controller(declared)} while it is on"},
      else: :ok
  end

  defp check_type(:bool, value) when is_boolean(value), do: {:ok, value}
  defp check_type(:integer, value) when is_integer(value), do: {:ok, value}
  defp check_type(:double, value) when is_number(value), do: {:ok, value * 1.0}
  defp check_type(:string, value) when is_binary(value), do: {:ok, value}
  defp check_type(type, value), do: {:error, "expected #{type}, got #{inspect(value)}"}

  defp check_constraint(%{kind: :range, min: min, max: max}, value)
       when value < min or value > max,
       do: {:error, "out of range #{min}..#{max}"}

  defp check_constraint(%{kind: :range, min: min, step: step}, value) when is_number(step) do
    steps = (value - min) / step

    if abs(steps - round(steps)) < 1.0e-9,
      do: :ok,
      else: {:error, "not a multiple of #{step} from #{min}"}
  end

  defp check_constraint(%{kind: :choices, values: choices}, value) do
    if value in choices, do: :ok, else: {:error, "expected one of #{Enum.join(choices, ", ")}"}
  end

  defp check_constraint(_constraint, _value), do: :ok

  defp check_order(state, declared, value, values) do
    above = if declared.greater_than, do: [{:above, declared.greater_than}], else: []

    below =
      for parameter <- all_parameters(state),
          parameter.greater_than == declared.id,
          do: {:below, parameter.id}

    Enum.find_value(above ++ below, :ok, fn {side, other} ->
      order_refusal(side, other, value, values[other])
    end)
  end

  defp order_refusal(_side, _other, _value, nil), do: nil

  defp order_refusal(:above, other, value, other_value) when value <= other_value,
    do: {:error, "must be above #{other} (#{other_value})"}

  defp order_refusal(:below, other, value, other_value) when value >= other_value,
    do: {:error, "must stay below #{other} (#{other_value})"}

  defp order_refusal(_side, _other, _value, _other_value), do: nil

  # Switching an automatic mode off sets what it controls to the values it left.
  defp release_controlled(state, declared, false, values) do
    if values[declared.id] == true do
      state
      |> all_parameters()
      |> Enum.filter(&(controller(&1) == declared.id))
      |> Enum.reduce_while({:ok, %{}}, &release_one/2)
    else
      {:ok, %{}}
    end
  end

  defp release_controlled(_state, _declared, _value, _values), do: {:ok, %{}}

  defp release_one(controlled, {:ok, released}) do
    case read(controlled) do
      nil ->
        {:cont, {:ok, released}}

      value ->
        case call_set(controlled, value) do
          :ok -> {:cont, {:ok, Map.put(released, controlled.id, value)}}
          error -> {:halt, error}
        end
    end
  end

  defp apply_changed(state, declared) do
    {values, _state} = read_values(state, related_ids(state, declared))
    value = Map.fetch!(state.changed, declared.id)

    unless automatic?(declared, values) do
      with {:error, reason} <- call_set(declared, value) do
        Logger.warning(
          "vision parameter #{declared.id} = #{inspect(value)} not set back: #{reason}"
        )
      end
    end
  end

  defp call_set(declared, value) do
    case declared.set.(value) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "not applied: #{inspect(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "not applied: #{inspect(reason)}"}
  end

  defp read(declared) do
    declared.get.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp read_status(%{status: status}) when is_function(status, 0) do
    status.()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp read_status(_group), do: nil

  # Values by id; the first value read of each parameter is its default.
  defp read_values(state, ids) do
    Enum.reduce(Enum.uniq(ids), {%{}, state}, fn id, {values, state} ->
      value = if declared = find(state, id), do: read(declared)

      state =
        if is_nil(value) or Map.has_key?(state.defaults, id),
          do: state,
          else: put_in(state.defaults[id], value)

      {Map.put(values, id, value), state}
    end)
  end

  defp read_parameter(state, declared) do
    {values, state} = read_values(state, related_ids(state, declared))
    {to_parameter(declared, values, state), state}
  end

  defp related_ids(state, declared) do
    dependents =
      for parameter <- all_parameters(state),
          parameter.greater_than == declared.id,
          do: parameter.id

    [declared.id, controller(declared), declared.greater_than | dependents]
    |> Enum.reject(&is_nil/1)
  end

  defp to_group(group, values, state) do
    %Group{
      id: group.id,
      name: group.name,
      summary: group.summary,
      kind: group.kind,
      placement: group.placement,
      position: group.position,
      status: read_status(group),
      parameters: Enum.map(group.parameters, &to_parameter(&1, values, state))
    }
  end

  defp to_parameter(declared, values, state) do
    Parameter
    |> struct(Map.take(declared, @parameter_fields))
    |> Map.merge(%{
      value: values[declared.id],
      default: state.defaults[declared.id],
      saved: state.saved[declared.id],
      state: parameter_state(declared, values, state)
    })
  end

  defp parameter_state(declared, values, state) do
    cond do
      automatic?(declared, values) ->
        :automatic

      declared.applies == :build ->
        :builtin

      values[declared.id] != Map.get(state.saved, declared.id, state.defaults[declared.id]) ->
        :unsaved

      Map.has_key?(state.saved, declared.id) ->
        :saved

      true ->
        :builtin
    end
  end

  defp automatic?(declared, values) do
    case controller(declared) do
      nil -> false
      controller -> values[controller] == true
    end
  end

  defp controller(%{applies: {:auto, controller}}), do: controller
  defp controller(_declared), do: nil

  defp normalize_group(group) do
    group
    |> Map.put_new(:status, nil)
    |> Map.update!(:parameters, fn parameters ->
      Enum.map(parameters, &normalize_parameter(&1, group.id))
    end)
  end

  defp normalize_parameter(declared, group_id) do
    declared
    |> Map.merge(%{id: "#{group_id}.#{declared.name}", group: group_id})
    |> Map.put_new(:applies, :live)
    |> Map.put_new(:constraint, nil)
    |> Map.update(:greater_than, nil, &"#{group_id}.#{&1}")
  end

  defp sorted_groups(state) do
    state.groups
    |> Map.values()
    |> List.flatten()
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  defp all_parameters(state), do: state |> sorted_groups() |> Enum.flat_map(& &1.parameters)

  defp find(state, id), do: Enum.find(all_parameters(state), &(&1.id == id))

  defp drop_owner(state, owner) do
    case Map.pop(state.owners, owner) do
      {nil, _owners} ->
        state

      {reference, owners} ->
        Process.demonitor(reference, [:flush])
        %{state | owners: owners, groups: Map.delete(state.groups, owner)}
    end
  end
end
