defmodule VisionCore.Camera.StoredFile do
  @moduledoc """
  The file a camera of its own keeps at runtime, its calibration
  (`VisionCore.Camera.Calibration`) or its pose (`VisionCore.Camera.Pose`):
  written whole or not at all, through a temporary file synced then
  renamed over it, removed, and dated. Each change is logged under the
  module that asks for it.
  """
  require Logger

  @doc "Writes `text` to `path` whole or not at all; `{:error, message}` when it cannot."
  @spec write(Path.t(), String.t(), module()) :: :ok | {:error, String.t()}
  def write(path, text, owner) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, text, [:sync]),
         :ok <- File.rename(temporary, path) do
      Logger.info("#{owner} wrote #{byte_size(text)} B → #{path}")
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "cannot write #{path}: #{file_error(reason)}"}
    end
  end

  @doc "Removes the file at `path`; `{:error, message}` when it cannot."
  @spec remove(Path.t(), module()) :: :ok | {:error, String.t()}
  def remove(path, owner) do
    case File.rm(path) do
      :ok -> Logger.info("#{owner} removed #{path}")
      {:error, reason} -> {:error, "cannot remove #{path}: #{file_error(reason)}"}
    end
  end

  @doc "When the file at `path` was last written, `nil` when it cannot be read."
  @spec written_at(Path.t()) :: DateTime.t() | nil
  def written_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> DateTime.from_unix!(stat.mtime)
      {:error, _reason} -> nil
    end
  end

  @doc "`File`'s `reason` in words."
  @spec file_error(term()) :: String.t()
  def file_error(reason), do: reason |> :file.format_error() |> List.to_string()
end
