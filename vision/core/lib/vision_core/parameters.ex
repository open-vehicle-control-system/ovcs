defmodule VisionCore.Parameters do
  @moduledoc """
  The vision unit's parameters: the settings of its components and pipeline
  stages, with what each accepts, when it applies and whether it differs from
  its saved value or built-in default.

  The process owning a component or stage declares its groups with
  `declare/2`, giving each parameter a `get` and a `set` function run in this
  process. `get` is read on every listing, so the value listed is the one in
  use. A group may give its `values` instead, read once per listing for its
  parameters without a `get`. A parameter with `applies: {:auto, controller}` is set by that
  controller's automatic mode while the controller is `true`.

  A listing (`groups/1`) gives each read `:listing_timeout_ms`, in a
  process of its own. An owner that does not answer in time is listed
  without its values and statuses and is not asked again in that
  listing, so one owner that hangs holds a listing back once, not once
  per group.

  Saved values are applied when their group is declared. One that no longer
  fits the parameter's type, constraint or relation, or of a parameter its
  group no longer declares or now fixes in the build, is dropped from the
  store with a log line; one the owner fails to set is kept for the next
  declaration, and left out of `save/1` until it is applied or the parameter
  is set. Values set since the last `save/1` are applied after them.
  Both are applied again when a restarted owner declares its groups.
  A parameter whose value cannot be read is never unsaved.

  A parameter's default is the `default` it is first declared with, or else
  the first value its `get` returns; either is kept while the registry runs.
  A value read after one was set through the registry, a saved one
  included, is never a default: a parameter that could not be read before
  then has none, and neither `reset/2` nor `discard/1` sets it back.

  ROS 2 and the API are adapters reading and setting parameters here.
  """
  use GenServer
  require Logger

  alias VisionCore.Parameters.{Check, Group, Parameter, Store}

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
          optional(:get) => (-> term()),
          optional(:set) => (term() -> :ok | {:error, String.t()}),
          optional(:constraint) => constraint(),
          optional(:applies) => applies(),
          optional(:greater_than) => String.t(),
          optional(:description) => String.t(),
          optional(:default) => term()
        }
  @type group_declaration :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:summary) => String.t(),
          optional(:explanation) => String.t(),
          required(:kind) => :component | :stage,
          required(:pipeline) => atom(),
          required(:position) => non_neg_integer(),
          optional(:status) => (-> {:ok | :warning | :off, String.t()} | nil),
          optional(:compute) => Group.compute(),
          optional(:values) => (-> %{String.t() => term()}),
          required(:parameters) => [declaration()]
        }

  @default_listing_timeout_ms 1_000

  @parameter_fields [:id, :group, :name, :type, :constraint, :applies, :greater_than] ++
                      [:description]

  @doc """
  A step of the pipeline `pipeline`: the group `<pipeline>.<id>`, named
  `name`, at `position` in the pipeline, `fields` giving its summary,
  explanation, compute and parameters.
  """
  @spec step(atom(), String.t(), String.t(), non_neg_integer(), map()) :: group_declaration()
  def step(pipeline, id, name, position, fields) do
    Map.merge(
      %{
        id: "#{pipeline}.#{id}",
        name: name,
        kind: :stage,
        pipeline: pipeline,
        position: position
      },
      fields
    )
  end

  @doc "The `:compute` of a step that runs in Elixir on the CPU."
  @spec on_the_beam() :: %{runs_on: :cpu, implementation: :elixir, backend: nil}
  def on_the_beam, do: %{runs_on: :cpu, implementation: :elixir, backend: nil}

  @doc """
  Starts the registry. Options: `:store`, the module holding saved values
  (`VisionCore.Parameters.Store`), `:name` (`VisionCore.Parameters`), and
  `:listing_timeout_ms` (`1000`), how long `groups/1` waits for an
  owner's values: one that does not answer in time is listed without its
  values and its statuses, and is not asked again in that listing.
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
  Checks `value` against parameter `id` with `VisionCore.Parameters.Check`
  and applies it; `{:error, :not_found}` when there is no such parameter.
  Switching an automatic mode off, here or when a saved or unsaved value is
  applied, first sets each parameter it controls to the value it left,
  brought within its range.
  """
  @spec set(GenServer.server(), id(), term()) ::
          {:ok, Parameter.t()} | {:error, :not_found | String.t()}
  def set(server \\ __MODULE__, id, value), do: GenServer.call(server, {:set, id, value})

  @doc """
  `set/3`, then stores the value of parameter `id` alone, as `save/1` would;
  other unsaved changes stay unsaved. A value applied but not stored is
  answered as an error and stays an unsaved change.
  """
  @spec set_and_save(GenServer.server(), id(), term()) ::
          {:ok, Parameter.t()} | {:error, :not_found | String.t()}
  def set_and_save(server \\ __MODULE__, id, value),
    do: GenServer.call(server, {:set_and_save, id, value})

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
  `{:error, :not_found}` when the group or parameter does not exist.
  """
  @spec reset(GenServer.server(), :all | {:group, String.t()} | {:parameter, id()}) ::
          {:ok, [id()]} | {:error, :not_found | String.t()}
  def reset(server \\ __MODULE__, scope), do: GenServer.call(server, {:reset, scope})

  @doc """
  Deletes the saved value of `id` now and forgets its unsaved change. A
  saved value the store could not delete stays saved, and the store's
  error is answered.
  """
  @spec forget(GenServer.server(), id()) :: :ok | {:error, String.t()}
  def forget(server \\ __MODULE__, id), do: GenServer.call(server, {:forget, id})

  @doc """
  The monotonic time, in milliseconds, of the latest value applied to an
  owner: by `set/3`, `set_and_save/3`, `discard/1` or `reset/2`, or when a
  saved or unsaved value is applied as a group is declared. `nil` before
  any.
  """
  @spec last_change(GenServer.server()) :: integer() | nil
  def last_change(server \\ __MODULE__), do: GenServer.call(server, :last_change)

  @impl GenServer
  def init(opts) do
    store = Keyword.get(opts, :store, Store)

    {:ok,
     %{
       listing_timeout_ms:
         VisionCore.Options.integer!(opts, :listing_timeout_ms, @default_listing_timeout_ms, 1),
       store: store,
       saved: store.load(),
       groups: %{},
       owners: %{},
       defaults: %{},
       changed: %{},
       # Ids of saved values their owner failed to set.
       unapplied_saved: MapSet.new(),
       # Ids set through the registry: a value read from then on is no default.
       set_ids: MapSet.new(),
       last_change_ms: nil
     }}
  end

  @impl GenServer
  def handle_call({:declare, groups}, {owner, _tag}, state) do
    state = drop_owner(state, owner)
    groups = Enum.map(groups, &normalize_group(&1, owner))

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
    ids = Enum.map(all_parameters(state), & &1.id)
    {values, late, state} = read_all(state, ids, MapSet.new())

    {groups, _late} =
      state
      |> sorted_groups()
      |> Enum.map_reduce(late, &to_group(&1, values, state, &2))

    {:reply, groups, state}
  end

  def handle_call(:last_change, _from, state), do: {:reply, state.last_change_ms, state}

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
    {reply, state} = set_value(state, id, value)
    {:reply, reply, state}
  end

  def handle_call({:set_and_save, id, value}, _from, state) do
    case set_value(state, id, value) do
      {{:ok, _parameter}, state} ->
        declared = find(state, id)

        case store_values(state, [declared]) do
          {:ok, _ids, state} ->
            {parameter, state} = read_parameter(state, declared)
            {:reply, {:ok, parameter}, state}

          {:error, reason, state} ->
            {:reply, {:error, "applied but not saved: #{reason}"}, state}
        end

      {refused, state} ->
        {:reply, refused, state}
    end
  end

  def handle_call(:save, _from, state) do
    parameters =
      Enum.reject(
        all_parameters(state),
        &(&1.applies == :build or MapSet.member?(state.unapplied_saved, &1.id))
      )

    case store_values(state, parameters) do
      {:ok, ids, state} -> {:reply, {:ok, ids}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:discard, _from, state) do
    reference = fn declared, values ->
      with :unsaved <- parameter_state(declared, values, state),
           value when not is_nil(value) <-
             Map.get(state.saved, declared.id, state.defaults[declared.id]),
           do: {:ok, value}
    end

    {set_ids, applied, refused} =
      apply_values(state, all_parameters(state), reference, &apply_value/4)

    log_refused(refused, "not set back")
    kept = for {declared, _value, _reason} <- refused, do: declared.id
    state = %{state | changed: Map.take(state.changed, kept)} |> mark_applied(Map.keys(applied))
    {:reply, {:ok, set_ids}, touch(state, applied)}
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

        state =
          %{state | changed: Map.merge(state.changed, applied)}
          |> mark_applied(Map.keys(applied))
          |> touch(applied)

        {:reply, reset_reply(set_ids, refused), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    {deleted, state} = delete_saved(state, Enum.filter([id], &Map.has_key?(state.saved, &1)))
    {:reply, deleted, %{state | changed: Map.delete(state.changed, id)} |> mark_applied([id])}
  end

  @impl GenServer
  def handle_continue({:apply, owner}, state) do
    groups = Map.get(state.groups, owner, [])
    declared = Enum.flat_map(groups, & &1.parameters)
    {_values, state} = read_values(state, Enum.map(declared, & &1.id))

    saved = fn parameter, _values -> Map.fetch(state.saved, parameter.id) end
    {_ids, saved_applied, refused} = apply_values(state, declared, saved, &apply_saved/4)
    {not_set, refused} = Enum.split_with(refused, &match?({_, _, {:owner, _}}, &1))

    log_refused(
      for({declared, value, {:owner, reason}} <- not_set, do: {declared, value, reason}),
      "kept, not applied"
    )

    unapplied_saved =
      state.unapplied_saved
      |> MapSet.difference(MapSet.new(declared, & &1.id))
      |> MapSet.union(MapSet.new(not_set, fn {parameter, _value, _reason} -> parameter.id end))

    state = %{state | unapplied_saved: unapplied_saved}

    state =
      drop_saved(
        state,
        undeclared_saved(state, groups) ++ build_saved(state, declared) ++ refused
      )

    changed = fn parameter, _values -> Map.fetch(state.changed, parameter.id) end
    {_ids, changed_applied, refused} = apply_values(state, declared, changed, &apply_value/4)
    log_refused(refused, "not set back")

    {:noreply, state |> touch(saved_applied) |> touch(changed_applied)}
  end

  @impl GenServer
  def handle_info({:DOWN, _reference, :process, owner, _reason}, state),
    do: {:noreply, drop_owner(state, owner)}

  def handle_info(_message, state), do: {:noreply, state}

  defp set_value(state, id, value) do
    case find(state, id) do
      nil ->
        log_refused_set(id, value, "unknown parameter")
        {{:error, :not_found}, state}

      declared ->
        {values, state} = read_values(state, related_ids(state, declared))

        case apply_value(state, declared, value, values) do
          {:ok, applied} ->
            state = %{state | changed: Map.merge(state.changed, applied)}
            state = state |> mark_applied(Map.keys(applied)) |> touch(applied)
            {parameter, state} = read_parameter(state, declared)
            {{:ok, parameter}, state}

          {:error, reason} ->
            log_refused_set(id, value, reason)
            {{:error, reason}, state}
        end
    end
  end

  defp log_refused_set(id, value, reason),
    do: Logger.info("vision parameter #{id} = #{inspect(value)} refused: #{reason}")

  defp touch(state, applied) when applied == %{}, do: state

  defp touch(state, applied) do
    %{
      state
      | last_change_ms: System.monotonic_time(:millisecond),
        set_ids: MapSet.union(state.set_ids, MapSet.new(Map.keys(applied)))
    }
  end

  # A parameter set again no longer waits for its saved value.
  defp mark_applied(state, ids),
    do: %{state | unapplied_saved: MapSet.difference(state.unapplied_saved, MapSet.new(ids))}

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
         {:ok, value} <- Check.value(declared.type, declared.constraint, value),
         :ok <- Check.order(value, order_relations(state, declared, values)) do
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

  # A value the store could not delete stays saved, and is dropped again at the next declaration.
  defp drop_saved(state, refused) do
    log_refused(refused, "dropped")
    ids = for {declared, _value, _reason} <- refused, do: declared.id

    case delete_saved(state, ids) do
      {:ok, state} ->
        state

      {{:error, reason}, state} ->
        for id <- ids, do: Logger.warning("vision parameter #{id} still saved: #{reason}")
        state
    end
  end

  # The saved values of `ids` deleted from the store, then from the registry: neither on a failed write.
  defp delete_saved(state, []), do: {:ok, state}

  defp delete_saved(state, ids) do
    case write_changes(state.store, Map.new(ids, &{&1, :delete})) do
      :ok -> {:ok, %{state | saved: Map.drop(state.saved, ids)}}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # Stores the values of `parameters`; a failed write keeps the unsaved changes.
  defp store_values(state, parameters) do
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
        {:ok, Map.keys(changes), %{state | saved: saved, changed: changed}}

      {:error, reason} ->
        {:error, reason, state}
    end
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
      [] -> {:error, :not_found}
      parameters -> {:ok, parameters}
    end
  end

  defp in_scope(state, {:parameter, id}) do
    case find(state, id) do
      nil -> {:error, :not_found}
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

  # The parameters `declared` must stay above or below, with their values.
  defp order_relations(state, declared, values) do
    above =
      if declared.greater_than,
        do: [above: {declared.greater_than, values[declared.greater_than]}],
        else: []

    below =
      for parameter <- all_parameters(state),
          parameter.greater_than == declared.id,
          do: {:below, {parameter.id, values[parameter.id]}}

    above ++ below
  end

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
    {value, _group_values, nil} = read(controlled, %{}, nil, nil)

    case value do
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

  # `late` holds the owners that did not answer in this listing; `nil` outside a listing.
  defp read(nil, group_values, _timeout_ms, late), do: {nil, group_values, late}

  defp read(%{get: get} = declared, group_values, timeout_ms, late) do
    {value, late} = ask(get, declared.owner, timeout_ms, late)
    {value, group_values, late}
  end

  defp read(%{group: group, values: values} = declared, group_values, timeout_ms, late) do
    case group_values do
      %{^group => read} ->
        {Map.get(read, declared.name), group_values, late}

      _unread ->
        {read, late} = ask(values, declared.owner, timeout_ms, late)
        read = read || %{}
        {Map.get(read, declared.name), Map.put(group_values, group, read), late}
    end
  end

  # Outside a listing a read is bounded by its own calls.
  defp ask(read, _owner, _timeout_ms, nil), do: {guarded(read), nil}

  defp ask(read, owner, timeout_ms, late) do
    if MapSet.member?(late, owner) do
      {nil, late}
    else
      case answered(read, timeout_ms) do
        {:ok, value} -> {value, late}
        :late -> {nil, MapSet.put(late, owner)}
      end
    end
  end

  # `read`'s value when it comes within `timeout_ms`, in a process of its own, killed past it.
  defp answered(read, timeout_ms) do
    task = Task.async(fn -> guarded(read) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> {:ok, value}
      _late_or_killed -> :late
    end
  end

  defp guarded(read) do
    read.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp read_status(%{status: status} = group, timeout_ms, late) when is_function(status, 0),
    do: ask(status, group.owner, timeout_ms, late)

  defp read_status(_group, _timeout_ms, late), do: {nil, late}

  defp read_values(state, ids) do
    {values, nil, state} = read_all(state, ids, nil)
    {values, state}
  end

  # Values by id; the first value read of each parameter, unless set by then, is its default.
  defp read_all(state, ids, late) do
    {values, _group_values, late, state} =
      Enum.reduce(Enum.uniq(ids), {%{}, %{}, late, state}, fn id, acc ->
        {values, group_values, late, state} = acc

        {value, group_values, late} =
          read(find(state, id), group_values, state.listing_timeout_ms, late)

        state =
          if is_nil(value) or Map.has_key?(state.defaults, id) or
               MapSet.member?(state.set_ids, id),
             do: state,
             else: put_in(state.defaults[id], value)

        {Map.put(values, id, value), group_values, late, state}
      end)

    {values, late, state}
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

  defp to_group(group, values, state, late) do
    {status, late} = read_status(group, state.listing_timeout_ms, late)

    group = %Group{
      id: group.id,
      name: group.name,
      summary: group.summary,
      explanation: Map.get(group, :explanation),
      kind: group.kind,
      pipeline: group.pipeline,
      position: group.position,
      status: status,
      compute: Map.get(group, :compute),
      parameters: Enum.map(group.parameters, &to_parameter(&1, values, state))
    }

    {group, late}
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

  defp normalize_group(group, owner) do
    group
    |> Map.put(:owner, owner)
    |> Map.put_new(:status, nil)
    |> Map.update!(:parameters, fn parameters ->
      Enum.map(parameters, fn parameter ->
        parameter
        |> normalize_parameter(group.id)
        |> put_group_values(group)
        |> Map.put(:owner, owner)
      end)
    end)
  end

  # A parameter without a `get` reads its value from its group's `values`.
  defp put_group_values(%{get: _get} = declared, _group), do: declared
  defp put_group_values(declared, %{values: values}), do: Map.put(declared, :values, values)

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
