defmodule VisionCore.Stereo.Matcher do
  @moduledoc """
  The `NxStereo.Matcher` server of vision_core's native segments
  (`VisionCore.Stereo.NativeSegment`), registered under this module's
  name, running the `stereo_match` binary nx_stereo builds unless `:path`
  names another. It takes `NxStereo.Matcher`'s options.

  `VisionCore.Application` starts it with `config :vision_core,
  :stereo_match_path` and `:stereo_match_threads`.
  """

  @doc "The child spec of the matcher server, started with `opts`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the matcher server; see `NxStereo.Matcher` for `opts`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:name, __MODULE__)
    |> NxStereo.Matcher.start_link()
  end

  @doc "See `NxStereo.Matcher.send_run/6`."
  defdelegate send_run(matcher, owner, segment_id, version, configuration, request),
    to: NxStereo.Matcher
end
