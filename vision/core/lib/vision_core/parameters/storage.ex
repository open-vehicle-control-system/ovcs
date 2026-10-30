defmodule VisionCore.Parameters.Storage do
  @moduledoc """
  Supervises `VisionCore.Repo` and runs its migrations on every boot.

  Starts as `:ignore` when the database cannot be opened or migrated, so the
  vision core runs on the parameters' defaults and saving answers an error.

  ## Options

    * `:name` - the repo's registered name (`VisionCore.Repo`).
    * any other option is passed to the repo, overriding its configuration.
  """
  require Logger

  alias VisionCore.Repo

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    {name, repo_opts} = Keyword.pop(opts, :name, Repo)

    children = [
      {Repo, Keyword.put(repo_opts, :name, name)},
      {Ecto.Migrator, repos: [Repo], dynamic_repo: name}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:error, reason} ->
        Logger.error("#{__MODULE__} failed to start, saved parameters down: #{inspect(reason)}")
        :ignore

      started ->
        started
    end
  end
end
