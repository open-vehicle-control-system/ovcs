defmodule PropertyTable.Matcher do
  @moduledoc """
  Behaviour for customizing the Matcher logic for filtering and dispatching events
  """

  @doc """
  Check whether a property is valid

  Returns `:ok` on success or `{:error, error}` where `error` is an `Exception` struct with
  information about the issue.
  """
  @callback check_property(PropertyTable.property()) :: :ok | {:error, Exception.t()}

  @doc """
  Check whether a pattern is valid

  Returns `:ok` on success or `{:error, error}` where `error` is an `Exception` struct with
  information about the issue.
  """
  @callback check_pattern(PropertyTable.pattern()) :: :ok | {:error, Exception.t()}

  @doc """
  Returns true if the pattern matches the specified property
  """
  @callback matches?(PropertyTable.pattern(), PropertyTable.property()) :: boolean()
end
