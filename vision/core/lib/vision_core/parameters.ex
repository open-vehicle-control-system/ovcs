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

  Saved values are applied when their group is declared. One that no longer
  fits the parameter's type, constraint or relation, or of a parameter its
  group no longer declares or now fixes in the build, is dropped from the
  store with a log line; one the owner fails to set is kept for the next
  declaration. Values set since the last `save/1` are applied after them.
  Both are applied again when a restarted owner declares its groups.
  A parameter whose value cannot be read is never unsaved.

  A parameter's default is the `default` it is first declared with, or else
  the first value its `get` returns; either is kept while the registry runs.

  ROS 2 and the API are adapters reading and setting parameters here.
  """
  use GenServer
  require Logger

  alias VisionCore.Parameters.{Export, Group, Parameter, Store}

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
          optional(:export) => [atom()] | [[atom()]],
          optional(:default) => term()
        }
  @type group_declaration :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:summary) => String.t(),
          required(:kind) => :component | :stage,
          required(:placement) => :flow | :side,
          required(:position) => non_neg_integer(),
          optional(:status) => (-> {:ok | :warning | :off, String.t()} | nil),
          optional(:compute) => Group.compute(),
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
  mode off, here or when a saved or unsaved value is applied, first sets each
  parameter it controls to the value it left, brought within its range.
  """
  @spec set(GenServer.server(), id(), term()) :: {:ok, Parameter.t()} | {:error, String.t()}
  def set(server \\ __MODULE__, id, value), do: GenServer.call(server, {:set, id, value})

  @doc "The number of parameters whose value differs from their saved value or default."
  @spec unsaved_count(GenServer.server()) :: non_neg_integer()
  def unsaved_count(server \\ __MODULE__), do: GenServer.call(server, :unsaved_count)

  @doc """
  Stores the value of every live parameter that differs from its default and
  deletes the saved value of the others, in one write. Values set by an
  automatic mode are not stored. Returns the ids whose saved value changed.
  """
  @spec save(GenServer.server()) :: {:ok, [id()]} | {:error, String.t()}
  def save(server \\ __MODULE__), do: GenServer.call(server, :save)

  @doc "Sets every unsaved parameter back to its saved value, or its default without one."
  @spec discard(GenServer.server()) :: {:ok, [id()]}
  def discard(server \\ __MODULE__), do: GenServer.call(server, :discard)

  @doc """
  Sets the live parameters in scope back to their default, as unsaved
  changes. Parameters set by an automatic mode are left alone.
  """
  @spec reset(GenServer.server(), :all | {:group, String.t()} | {:parameter, id()}) ::
          {:ok, [id()]} | {:error, String.t()}
  def reset(server \\ __MODULE__, scope), do: GenServer.call(server, {:reset, scope})

  @doc "Deletes the saved value of `id` now and forgets its unsaved change."
  @spec forget(GenServer.server(), id()) :: :ok
  def forget(server \\ __MODULE__, id), do: GenServer.call(server, {:forget, id})

  @doc "The saved values as composer snippets; see `VisionCore.Parameters.Export`."
  @spec export(GenServer.server()) :: String.t()
  def export(server \\ __MODULE__), do: GenServer.call(server, :export)

  @impl GenServer
  def init(opts) do
    store = Keyword.get(opts, :store, Store)

    {:ok,
     %{
       store: store,
       saved: store.load(),
       groups: %{},
       owners: %{},
       defaults: %{},
       changed: %{}
     }}
  end

  @impl GenServer
  def handle_call({:declare, groups}, {owner, _tag}, state) do
    state = drop_owner(state, owner)
    groups = Enum.map(groups, &normalize_group/1)

    declared_defaults =
      for group <- groups, %{default: default} = parameter <- group.parameters, into: %{} do
        {parameter.id, default}
      end

    state = %{
      state
      | groups: Map.put(state.groups, owner, groups),
        owners: Map.put(state.owners, owner, Process.monitor(owner)),
        defaults: Map.merge(declared_defaults, state.defaults)
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

  def handle_call(:save, _from, state) do
    parameters = Enum.reject(all_parameters(state), &(&1.applies == :build))
    {values, state} = read_values(state, Enum.flat_map(parameters, &related_ids(state, &1)))
    readable = Enum.reject(parameters, &is_nil(values[&1.id]))
    rows = Enum.flat_map(readable, &saved_row(&1, values, state))
    changes = row_changes(Enum.map(readable, & &1.id), Map.new(rows), state.saved)

    case write_changes(state.store, changes) do
      :ok ->
        saved =
          Enum.reduce(changes, state.saved, fn
            {id, :delete}, saved -> Map.delete(saved, id)
            {id, value}, saved -> Map.put(saved, id, value)
          end)

        changed = Map.drop(state.changed, Enum.map(readable, & &1.id))
        {:reply, {:ok, Map.keys(changes)}, %{state | saved: saved, changed: changed}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:discard, _from, state) do
    reference = fn declared, values ->
      if parameter_state(declared, values, state) == :unsaved,
        do: {:ok, Map.get(state.saved, declared.id, state.defaults[declared.id])}
    end

    {set_ids, applied, refused} =
      apply_values(state, all_parameters(state), reference, &apply_value/4)

    log_refused(refused, "not set back")
    kept = for {declared, _value, _reason} <- refused, do: declared.id
    changed = Map.drop(state.changed, Map.keys(applied) -- kept)
    {:reply, {:ok, set_ids}, %{state | changed: changed}}
  end

  def handle_call({:reset, scope}, _from, state) do
    case in_scope(state, scope) do
      {:ok, parameters} ->
        default = fn declared, values ->
          value = values[declared.id]
          default = state.defaults[declared.id]

          if not is_nil(value) and not is_nil(default) and value != default,
            do: {:ok, default}
        end

        {set_ids, applied, refused} = apply_values(state, parameters, default, &apply_value/4)
        log_refused(refused, "not reset")
        state = %{state | changed: Map.merge(state.changed, applied)}
        {:reply, reset_reply(set_ids, refused), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    state = delete_saved(state, Enum.filter([id], &Map.has_key?(state.saved, &1)))
    {:reply, :ok, %{state | changed: Map.delete(state.changed, id)}}
  end

  def handle_call(:export, _from, state) do
    rows =
      for {id, value} <- state.saved,
          path <- export_paths(find(state, id)),
          do: {path, id, value}

    {:reply, Export.render(rows), state}
  end

  # A parameter applied to several places, such as both cameras, has a path for each.
  defp export_paths(nil), do: [:not_running]
  defp export_paths(%{export: [path | _] = paths}) when is_list(path), do: paths
  defp export_paths(%{export: path}), do: [path]

  @impl GenServer
  def handle_continue({:apply, owner}, state) do
    groups = Map.get(state.groups, owner, [])
    declared = Enum.flat_map(groups, & &1.parameters)
    {_values, state} = read_values(state, Enum.map(declared, & &1.id))

    saved = fn parameter, _values -> Map.fetch(state.saved, parameter.id) end
    {_ids, _applied, refused} = apply_values(state, declared, saved, &apply_saved/4)
    {not_set, refused} = Enum.split_with(refused, &match?({_, _, {:owner, _}}, &1))

    log_refused(
      for({declared, value, {:owner, reason}} <- not_set, do: {declared, value, reason}),
      "kept, not applied"
    )

    state =
      drop_saved(
        state,
        undeclared_saved(state, groups) ++ build_saved(state, declared) ++ refused
      )

    changed = fn parameter, _values -> Map.fetch(state.changed, parameter.id) end
    {_ids, _applied, refused} = apply_values(state, declared, changed, &apply_value/4)
    log_refused(refused, "not set back")

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
    Logger.info("vision parameter #{id} = #{inspect(value)} refused: #{reason}")
    {:reply, {:error, reason}, state}
  end

  # The values applied by id, or the first refusal.
  defp apply_value(state, declared, value, values) do
    with {:ok, value} <- check_value(state, declared, value, values) do
      apply_checked(state, declared, value, values)
    end
  end

  # As apply_value/4, with the owner's refusal told apart from the model's.
  defp apply_saved(state, declared, value, values) do
    with {:ok, value} <- check_value(state, declared, value, values) do
      case apply_checked(state, declared, value, values) do
        {:ok, applied} -> {:ok, applied}
        {:error, reason} -> {:error, {:owner, reason}}
      end
    end
  end

  defp apply_checked(state, declared, value, values) do
    with {:ok, released} <- release_controlled(state, declared, value, values),
         :ok <- call_set(declared, value) do
      {:ok, Map.put(released, declared.id, value)}
    end
  end

  defp check_value(state, declared, value, values) do
    with :ok <- check_settable(declared, values),
         {:ok, value} <- check_type(declared.type, value),
         :ok <- check_constraint(declared.constraint, value),
         :ok <- check_order(state, declared, value, values) do
      {:ok, value}
    end
  end

  # Sets each `{:ok, value}` from `target`, controllers first: {ids set, values applied, refusals}.
  defp apply_values(state, parameters, target, apply) do
    controllers = MapSet.new(all_parameters(state), &controller/1)

    parameters
    |> Enum.reject(&(&1.applies == :build))
    |> Enum.split_with(&MapSet.member?(controllers, &1.id))
    |> Tuple.to_list()
    |> Enum.reduce({[], %{}, []}, fn batch, {ids, applied, refused} ->
      {values, _state} = read_values(state, Enum.flat_map(batch, &related_ids(state, &1)))

      targets =
        for parameter <- batch,
            {:ok, value} <- [target.(parameter, values)],
            do: {parameter, value}

      {batch_ids, batch_applied, batch_refused} = apply_batch(state, targets, apply)
      {ids ++ batch_ids, Map.merge(applied, batch_applied), refused ++ batch_refused}
    end)
  end

  # Refusals are retried while others go through: a relation may hold only once its other side is set.
  defp apply_batch(state, targets, apply) do
    {ids, applied, refused} =
      Enum.reduce(targets, {[], %{}, []}, fn {declared, value}, {ids, applied, refused} ->
        {values, _state} = read_values(state, related_ids(state, declared))

        if automatic?(declared, values) do
          {ids, applied, refused}
        else
          case apply.(state, declared, value, values) do
            {:ok, set} -> {[declared.id | ids], Map.merge(applied, set), refused}
            {:error, reason} -> {ids, applied, [{declared, value, reason} | refused]}
          end
        end
      end)

    ids = Enum.reverse(ids)
    refused = Enum.reverse(refused)

    if ids != [] and refused != [] do
      retry = for {declared, value, _reason} <- refused, do: {declared, value}
      {more_ids, more_applied, refused} = apply_batch(state, retry, apply)
      {ids ++ more_ids, Map.merge(applied, more_applied), refused}
    else
      {ids, applied, refused}
    end
  end

  defp log_refused(refused, outcome) do
    for {declared, value, reason} <- refused do
      Logger.warning("vision parameter #{declared.id} = #{inspect(value)} #{outcome}: #{reason}")
    end
  end

  # Saved values under the groups' ids that match none of their parameters.
  defp undeclared_saved(state, groups) do
    group_ids = MapSet.new(groups, & &1.id)

    for {id, value} <- state.saved,
        MapSet.member?(group_ids, group_id(id)),
        is_nil(find(state, id)),
        do: {%{id: id}, value, "no such parameter"}
  end

  defp build_saved(state, declared) do
    for %{applies: :build} = parameter <- declared,
        {:ok, value} <- [Map.fetch(state.saved, parameter.id)],
        do: {parameter, value, "fixed in the build"}
  end

  defp group_id(id), do: id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

  defp drop_saved(state, refused) do
    log_refused(refused, "dropped")
    delete_saved(state, for({declared, _value, _reason} <- refused, do: declared.id))
  end

  defp delete_saved(state, []), do: state

  defp delete_saved(state, ids) do
    write_changes(state.store, Map.new(ids, &{&1, :delete}))
    %{state | saved: Map.drop(state.saved, ids)}
  end

  defp write_changes(_store, changes) when changes == %{}, do: :ok
  defp write_changes(store, changes), do: store.write(changes)

  defp saved_row(declared, values, state) do
    value = values[declared.id]

    if automatic?(declared, values) or value == state.defaults[declared.id],
      do: [],
      else: [{declared.id, value}]
  end

  # The store changes turning the saved values of `ids` into `rows`.
  defp row_changes(ids, rows, saved) do
    for id <- ids, Map.fetch(rows, id) != Map.fetch(saved, id), into: %{} do
      case Map.fetch(rows, id) do
        {:ok, value} -> {id, value}
        :error -> {id, :delete}
      end
    end
  end

  defp in_scope(state, :all), do: {:ok, all_parameters(state)}

  defp in_scope(state, {:group, group_id}) do
    case Enum.filter(all_parameters(state), &(&1.group == group_id)) do
      [] -> {:error, "unknown group"}
      parameters -> {:ok, parameters}
    end
  end

  defp in_scope(state, {:parameter, id}) do
    case find(state, id) do
      nil -> {:error, "unknown parameter"}
      declared -> {:ok, [declared]}
    end
  end

  defp reset_reply(ids, []), do: {:ok, ids}

  defp reset_reply(_ids, refused),
    do:
      {:error,
       Enum.map_join(refused, "; ", fn {declared, _value, reason} ->
         "#{declared.id}: #{reason}"
       end)}

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
    if value in choices,
      do: :ok,
      else: {:error, "expected one of #{Enum.map_join(choices, ", ", &render_choice/1)}"}
  end

  defp check_constraint(_constraint, _value), do: :ok

  defp render_choice(nil), do: inspect(nil)

  defp render_choice(choice) when is_binary(choice) or is_atom(choice) or is_number(choice),
    do: to_string(choice)

  defp render_choice(choice), do: inspect(choice)

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
        value = within(controlled, value)

        case call_set(controlled, value) do
          :ok -> {:cont, {:ok, Map.put(released, controlled.id, value)}}
          error -> {:halt, error}
        end
    end
  end

  defp within(%{constraint: %{kind: :range, min: min, max: max}, type: type}, value)
       when is_number(value) do
    value = value |> max(min) |> min(max)
    if type == :double, do: value * 1.0, else: value
  end

  defp within(_declared, value), do: value

  defp call_set(declared, value) do
    case declared.set.(value) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "not applied: #{inspect(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    _kind, reason -> {:error, "not applied: #{inspect(reason)}"}
  end

  defp read(declared) do
    declared.get.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp read_status(%{status: status}) when is_function(status, 0) do
    status.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
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
      compute: Map.get(group, :compute),
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

      unsaved?(declared, values, state) ->
        :unsaved

      Map.has_key?(state.saved, declared.id) ->
        :saved

      true ->
        :builtin
    end
  end

  defp unsaved?(declared, values, state) do
    value = values[declared.id]

    not is_nil(value) and
      value != Map.get(state.saved, declared.id, state.defaults[declared.id])
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
    |> Map.put_new(:export, nil)
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
