defmodule VisionCore.Stereo.Check do
  @moduledoc """
  What `VisionCore.Stereo.PairCheck` and `VisionCore.Stereo.DepthCheck`
  share: a check's shape and when an issue is raised.

  A check has a `:level`, `:ok`, `:warning` as soon as it has an issue, or
  `:off` with nothing to judge, the `:camera` its issues point at, or
  `nil`, its `:issues`, and, when judged, its `:gauge` and figures.

  An issue is raised past its threshold and, once raised, stays until its
  figure falls below `0.8` of it: given the previous window's checks, a
  figure hovering at a threshold does not raise and clear the issue in
  turn.
  """

  # A raised issue clears only below this share of its threshold, so a value near it does not flap.
  @clear_ratio 0.8

  @type side :: :left | :right
  @type level :: :ok | :warning | :off
  @type t :: %{
          required(:level) => level(),
          required(:camera) => side() | nil,
          required(:issues) => [atom()],
          optional(atom()) => term()
        }

  @doc "The issues raised in `previous`, a window's checks by name, or none."
  @spec raised(%{atom() => t()} | nil) :: MapSet.t(atom())
  def raised(nil), do: MapSet.new()

  def raised(previous),
    do: MapSet.new(for {_name, %{issues: issues}} <- previous, issue <- issues, do: issue)

  @doc "Whether `value` is past `limit`, or, for an issue already `raised`, past its clearing point."
  @spec past?(number(), number(), atom(), MapSet.t(atom())) :: boolean()
  def past?(value, limit, issue, raised) do
    if MapSet.member?(raised, issue), do: value > limit * @clear_ratio, else: value > limit
  end

  @doc "A judged check: `:ok` without `issues`, or a warning pointing at `camera`, with its `figures`."
  @spec judged([atom()], side() | nil, map()) :: t()
  def judged([], _camera, figures), do: Map.merge(%{level: :ok, camera: nil, issues: []}, figures)

  def judged(issues, camera, figures),
    do: Map.merge(%{level: :warning, camera: camera, issues: issues}, figures)

  @doc "A check with nothing to judge."
  @spec off() :: t()
  def off, do: %{level: :off, camera: nil, issues: []}
end
