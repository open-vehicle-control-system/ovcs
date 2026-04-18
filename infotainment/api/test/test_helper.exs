{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = InfotainmentApi.Repo.start_link()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(InfotainmentApi.Repo, :manual)
