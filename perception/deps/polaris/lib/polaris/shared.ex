defmodule Polaris.Shared do
  @moduledoc false

  # Collection of private helper functions and
  # macros for enforcing shape/type constraints,
  # doing shape calculations, and even some
  # helper numerical definitions.

  import Nx.Defn

  @doc """
  Creates a zeros-like structure which matches the structure
  of the input.
  """
  deftransform zeros_like(params, opts \\ []) do
    fulls_like(params, 0, opts)
  end

  @doc """
  Creates a fulls-like tuple of inputs.
  """
  deftransform fulls_like(params, value, opts \\ []) do
    opts = Keyword.validate!(opts, [:type])
    fun = &Nx.broadcast(Nx.tensor(value, type: &2), &1)

    deep_new(params, fn x ->
      type = opts[:type] || Nx.type(x)
      fun.(Nx.shape(x), type)
    end)
  end

  @doc """
  Deep merges two possibly nested maps, applying fun to leaf values.
  """
  deftransform deep_merge(left, right, fun) do
    f = fn
      _, [] ->
        {nil, []}

      x, [y | t] ->
        {fun.(x, y), t}
    end

    case Nx.Defn.Composite.traverse(left, Nx.Defn.Composite.flatten_list([right]), f) do
      {merged, []} ->
        merged

      {_merged, _leftover} ->
        raise ArgumentError,
              "unable to merge arguments with incompatible" <>
                " structure"
    end
  end

  @doc """
  Creates a new map-like structure from a possible nested map, applying `fun`
  to each leaf.
  """
  deftransform deep_new(map, fun) do
    Nx.Defn.Composite.traverse(map, fun)
  end

  @doc """
  Deep reduces a map with an accumulator.
  """
  deftransform deep_reduce(map, acc, fun) do
    Nx.Defn.Composite.reduce(map, acc, fun)
  end

  @doc """
  Deep map-reduce a nested container with an accumulator.
  """
  deftransform deep_map_reduce(container, acc, fun) do
    Nx.Defn.Composite.traverse(container, acc, fun)
  end
end
