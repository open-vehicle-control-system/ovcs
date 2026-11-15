defmodule VisionApiWeb.RecordingController do
  @moduledoc """
  The bag exporter's recordings (`VisionCore.Recordings`), as
  `recordings` resources identified by their name: listed, read,
  started, stopped and deleted. `include=parts` puts their parts, the
  `recording-parts`, in `included`.

  Creating one starts a recording of the `preset` and `clock` its
  attributes name, `review` and `automatic` without them; changing its
  `state` to `stopped` stops it. A unit without a bag exporter has no
  recording to start or stop: 404.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Recordings
  alias VisionCore.Ros2.BagExporter

  @type_name "recordings"
  @relationships ["parts"]
  @attributes_pointer "/data/attributes"
  @state_pointer "/data/attributes/state"

  def index(conn, params) do
    case JsonApi.includes(params, @relationships) do
      {:ok, includes} -> render(conn, :index, recordings: Recordings.list(), includes: includes)
      :error -> refuse(conn, nil, :unsupported_include)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, includes} <- JsonApi.includes(params, @relationships),
         {:ok, recording} <- Recordings.fetch(id) do
      render(conn, :show, recording: recording, includes: includes)
    else
      :error -> refuse(conn, id, :unsupported_include)
      refusal -> refuse(conn, id, refusal)
    end
  end

  def create(conn, _params) do
    with {:ok, data} <- JsonApi.fetch_created(JsonApi.document(conn), @type_name),
         {:ok, attributes} <- fetch_attributes(data),
         {:ok, preset} <- choice(attributes, "preset", BagExporter.presets()),
         {:ok, clock} <- choice(attributes, "clock", BagExporter.clocks()),
         {:ok, recording} <-
           Recordings.start(Keyword.reject([preset: preset, clock: clock], &is_nil(elem(&1, 1)))) do
      conn
      |> put_status(:created)
      |> render(:show, recording: recording, includes: [])
    else
      refusal -> refuse(conn, nil, refusal)
    end
  end

  def update(conn, %{"id" => id}) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, @type_name, id),
         {:ok, state} <- fetch_state(data),
         :ok <- check_stopping(state),
         {:ok, recording} <- Recordings.stop(id, []) do
      render(conn, :show, recording: recording, includes: [])
    else
      refusal -> refuse(conn, id, refusal)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Recordings.delete(id) do
      :ok -> send_resp(conn, :no_content, "")
      refusal -> refuse(conn, id, refusal)
    end
  end

  defp fetch_attributes(%{"attributes" => %{} = attributes}), do: {:ok, attributes}

  defp fetch_attributes(%{"attributes" => _other}),
    do: {:error, 400, "attributes must be an object", [source: @attributes_pointer]}

  defp fetch_attributes(_data), do: {:ok, %{}}

  # The allowed atom whose text the attribute `key` holds, `nil` without it.
  defp choice(attributes, key, allowed) do
    case Map.fetch(attributes, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil ->
            {:error, 422,
             "#{key} must be one of #{Enum.map_join(allowed, ", ", &Atom.to_string/1)}, not #{inspect(value)}",
             [source: "#{@attributes_pointer}/#{key}"]}

          choice ->
            {:ok, choice}
        end
    end
  end

  defp fetch_state(%{"attributes" => %{"state" => state}}), do: {:ok, state}

  defp fetch_state(_data),
    do: {:error, 400, "data.attributes.state is required", [source: @state_pointer]}

  defp check_stopping("stopped"), do: :ok

  defp check_stopping(state),
    do:
      {:error, 422, "a recording's state changes to stopped only, not #{inspect(state)}",
       [source: @state_pointer]}

  defp refuse(conn, _id, {:error, _status, _detail, _options} = refusal),
    do: JsonApi.refuse(conn, refusal)

  defp refuse(conn, _id, :unsupported_include),
    do: JsonApi.error(conn, 400, "unsupported include", source: %{parameter: "include"})

  defp refuse(conn, id, {:error, :not_found}), do: JsonApi.error(conn, 404, "no recording #{id}")

  defp refuse(conn, _id, {:error, :no_bag_exporter}),
    do: JsonApi.error(conn, 404, "the unit has no bag exporter to record with")

  defp refuse(conn, _id, {:error, :busy}),
    do: JsonApi.error(conn, 409, "a recording is in progress: stop it first", title: "Recording")

  defp refuse(conn, _id, {:error, {:no_disk, reason}}),
    do: JsonApi.error(conn, 409, reason, title: "No disk")

  defp refuse(conn, id, {:error, :recording}),
    do: JsonApi.error(conn, 409, "#{id} is recording: stop it first", title: "Recording")

  defp refuse(conn, id, {:error, stopped}) when stopped in [:stopped, :not_recording],
    do: JsonApi.error(conn, 422, "#{id} is stopped already", source: @state_pointer)

  defp refuse(conn, _id, {:error, :not_running}),
    do:
      JsonApi.error(conn, 503, "the bag exporter does not run", title: "Bag exporter not running")

  defp refuse(conn, _id, {:error, :timeout}),
    do: JsonApi.error(conn, 504, "the bag exporter did not answer in time")

  defp refuse(conn, _id, {:error, {:failed, reason}}), do: JsonApi.error(conn, 500, reason)

  defp refuse(conn, _id, {:error, :unknown_call}),
    do: JsonApi.error(conn, 500, "the bag exporter takes no call")
end
