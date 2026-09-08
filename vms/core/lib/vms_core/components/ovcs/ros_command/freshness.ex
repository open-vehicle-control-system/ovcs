defmodule VmsCore.Components.OVCS.RosCommand.Freshness do
  @moduledoc """
  Tells a command consumer whether its input is still being produced.

  `Cantastic.Emitter` retransmits a frame at its period whether or not
  anything new was written into it, so a frame arriving on time proves
  only that the bridge is alive. The bridge therefore increments the
  frame's `sequence` once per ROS sample, and this tracks it: a
  sequence that stops changing for longer than `timeout_ms` means the
  input is gone, whichever side of the link it went on. A frame that
  stops arriving altogether is the same case, since nothing advances
  the sequence either.

  Pure, like `RosBridge.InputWatchdog`: the caller passes its clock,
  calls `observe/3` on each frame and `check/2` on each tick, and
  `check/2` answers with the transition rather than the state so an
  outage is acted on and logged once.

  A new tracker starts stale, because nothing has commanded anything
  yet, and reports `:stale` on its first check after the timeout so a
  consumer that never receives a fresh frame says so once.
  """

  @enforce_keys [:timeout_ms, :created_at]
  defstruct [:timeout_ms, :created_at, :sequence, :fresh_at, stale: true, reported: false]

  @type transition :: :fresh | :stale | :unchanged
  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          created_at: integer(),
          sequence: non_neg_integer() | nil,
          fresh_at: integer() | nil,
          stale: boolean(),
          reported: boolean()
        }

  @spec new(pos_integer(), integer()) :: t()
  def new(timeout_ms, now) when is_integer(timeout_ms) and timeout_ms > 0 do
    %__MODULE__{timeout_ms: timeout_ms, created_at: now}
  end

  @doc """
  Record a frame. `:new` when its sequence differs from the last one
  seen, `:repeat` for a retransmission of the same sample, which the
  caller should not apply as if it were fresh input.
  """
  @spec observe(t(), non_neg_integer(), integer()) :: {:new | :repeat, t()}
  def observe(%__MODULE__{sequence: sequence} = freshness, sequence, _now) do
    {:repeat, freshness}
  end

  def observe(%__MODULE__{} = freshness, sequence, now) do
    {:new, %{freshness | sequence: sequence, fresh_at: now}}
  end

  @doc """
  Report whether the input has just gone quiet or just come back, and
  `:unchanged` otherwise.
  """
  @spec check(t(), integer()) :: {transition(), t()}
  def check(%__MODULE__{} = freshness, now) do
    expired = expired?(freshness, now)

    cond do
      # Only a sample can make the input fresh; before the first one the
      # tracker is stale and merely quiet about it until the timeout.
      not expired and freshness.stale and not is_nil(freshness.fresh_at) ->
        {:fresh, %{freshness | stale: false, reported: true}}

      expired and not freshness.stale ->
        {:stale, %{freshness | stale: true, reported: true}}

      expired and not freshness.reported ->
        {:stale, %{freshness | stale: true, reported: true}}

      true ->
        {:unchanged, freshness}
    end
  end

  @spec stale?(t()) :: boolean()
  def stale?(%__MODULE__{stale: stale}), do: stale

  defp expired?(%__MODULE__{fresh_at: nil} = freshness, now) do
    now - freshness.created_at > freshness.timeout_ms
  end

  defp expired?(%__MODULE__{fresh_at: fresh_at, timeout_ms: timeout_ms}, now) do
    now - fresh_at > timeout_ms
  end
end
