{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = VmsApi.Repo.start_link()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(VmsApi.Repo, :manual)
