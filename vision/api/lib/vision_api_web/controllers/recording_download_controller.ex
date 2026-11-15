defmodule VisionApiWeb.RecordingDownloadController do
  @moduledoc """
  A recording's download: the recording as one uncompressed tar,
  `<name>.tar`, each part a folder of its files
  (`VisionCore.Recordings.archive/2`), sent as it is read from the
  disks, with its length known first, so a browser shows the download's
  progress. A recording still recording grows: 409.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Recordings

  def show(conn, %{"id" => id}) do
    case Recordings.archive(id) do
      {:ok, archive} ->
        send_archive(conn, archive)

      {:error, :not_found} ->
        JsonApi.error(conn, 404, "no recording #{id}")

      {:error, :recording} ->
        JsonApi.error(conn, 409, "#{id} is recording: stop it first", title: "Recording")

      {:error, :timeout} ->
        JsonApi.error(conn, 504, "the bag exporter did not answer in time")

      {:error, {:failed, reason}} ->
        JsonApi.error(conn, 500, reason)

      {:error, :unknown_call} ->
        JsonApi.error(conn, 500, "the bag exporter takes no call")
    end
  end

  # A folder on a disk may be named with any character but `/`.
  defp quoted(filename), do: String.replace(filename, ~r/[^\w.-]/u, "_")

  defp send_archive(conn, archive) do
    conn =
      conn
      |> put_resp_content_type("application/x-tar", nil)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{quoted(archive.filename)}")
      )
      |> put_resp_header("content-length", Integer.to_string(archive.size))
      |> send_chunked(200)

    Enum.reduce_while(archive.stream, conn, fn block, conn ->
      case chunk(conn, block) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end
end
