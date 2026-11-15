defmodule VisionApiWeb.RecordingJSON do
  @moduledoc """
  Recordings (`VisionCore.Recording`) as `recordings` JSON:API
  resources, related to the `disk` they record on, `null` once stopped,
  and to their `parts`, `recording-parts` identified by their folder's
  name, each with its `number`, `bytes` and `disk`. A recording's drops
  are a list of `{topic, count}`: a topic is no JSON:API member name.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Recording

  @doc "The recordings, their parts in `included` when `includes` names `parts`."
  @spec index(%{recordings: [Recording.t()], includes: [String.t()]}) :: map()
  def index(%{recordings: recordings, includes: includes}),
    do: document(Enum.map(recordings, &data/1), recordings, includes)

  @doc "One recording, its parts in `included` when `includes` names `parts`."
  @spec show(%{recording: Recording.t(), includes: [String.t()]}) :: map()
  def show(%{recording: recording, includes: includes}),
    do: document(data(recording), [recording], includes)

  defp document(data, recordings, ["parts"]),
    do: %{
      data: data,
      included: Enum.flat_map(recordings, &Enum.map(&1.parts, fn part -> part(part) end))
    }

  defp document(data, _recordings, []), do: %{data: data}

  defp data(%Recording{} = recording) do
    JsonApi.resource(
      "recordings",
      recording.name,
      %{
        name: recording.name,
        state: Atom.to_string(recording.state),
        preset: recording.preset,
        clock: recording.clock,
        clockInUse: recording.clock_in_use,
        clockSynchronized: recording.clock_synchronized,
        startedAt: recording.started_at,
        durationMs: recording.duration_ms,
        bytes: recording.bytes,
        messages: recording.messages,
        dropped:
          for({topic, count} <- Enum.sort(recording.dropped), do: %{topic: topic, count: count})
      },
      %{
        disk: JsonApi.to_one("disks", recording.disk),
        parts: JsonApi.to_many("recording-parts", Enum.map(recording.parts, & &1.name))
      }
    )
  end

  defp part(part) do
    JsonApi.resource(
      "recording-parts",
      part.name,
      %{name: part.name, number: part.number, bytes: part.bytes},
      %{disk: JsonApi.to_one("disks", part.disk)}
    )
  end
end
