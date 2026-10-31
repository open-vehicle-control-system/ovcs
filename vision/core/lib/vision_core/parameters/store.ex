defmodule VisionCore.Parameters.Store do
  @moduledoc """
  Reads and writes the saved parameter values in `VisionCore.Repo`.

  Both calls answer when the database is unavailable: `load/0` returns no
  values, `write/1` returns an error.
  """
  import Ecto.Query
  require Logger

  alias VisionCore.Parameters.SavedValue
  alias VisionCore.Repo

  @unavailable "saved parameters unavailable"

  @doc """
  Every saved value, by parameter id. A row that cannot be decoded is skipped.
  """
  @spec load() :: %{String.t() => term()}
  def load do
    SavedValue
    |> Repo.all()
    |> Enum.reduce(%{}, &decode_into/2)
  rescue
    error -> unavailable(error)
  catch
    :exit, reason -> unavailable(reason)
  end

  @doc """
  Saves the given values in one transaction; `:delete` removes a saved value.
  """
  @spec write(%{String.t() => term() | :delete}) :: :ok | {:error, String.t()}
  def write(changes) do
    case Repo.transaction(fn -> Enum.each(changes, &write_one/1) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> failed(reason)
    end
  rescue
    error -> failed(error)
  catch
    :exit, reason -> failed(reason)
  end

  defp decode_into(%SavedValue{parameter_id: id, value: json}, values) do
    case Jason.decode(json) do
      {:ok, value} ->
        Map.put(values, id, value)

      {:error, _error} ->
        Logger.warning("saved parameter #{id} skipped: value is not valid JSON")
        values
    end
  end

  defp write_one({id, :delete}) do
    Repo.delete_all(from(v in SavedValue, where: v.parameter_id == ^id))
  end

  defp write_one({id, value}) do
    Repo.insert!(%SavedValue{parameter_id: id, value: Jason.encode!(value)},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :parameter_id
    )
  end

  defp unavailable(reason) do
    Logger.warning("#{@unavailable}: #{inspect(reason)}")
    %{}
  end

  defp failed(reason) do
    Logger.warning("#{@unavailable}: #{inspect(reason)}")
    {:error, @unavailable}
  end
end
