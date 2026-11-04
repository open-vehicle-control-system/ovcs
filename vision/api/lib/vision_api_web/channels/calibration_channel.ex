defmodule VisionApiWeb.CalibrationChannel do
  @moduledoc """
  Pushes the calibration session as `"session"` on join and on each change
  of `VisionCore.Calibration.Session`, and the calibration in use as
  `"in_use"` on join and each time the unit takes another one; both shaped
  by `VisionApiWeb.CalibrationJSON`. Joining subscribes to the session,
  which turns detection on in the core until the last subscriber leaves.

  Stops when the session restarts, and refuses the join while it is not
  running; see `VisionApiWeb.SourceMonitor`. A unit without a `:stereo`
  component refuses it with `%{reason: "no stereo unit"}`, which the
  client does not retry.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.{CalibrationJSON, CalibrationUnit, SourceMonitor}
  alias VisionCore.Calibration.Session
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Calibration

  @impl Phoenix.Channel
  def join("calibration", _payload, socket) do
    with {:ok, _config, prefix} <- CalibrationUnit.fetch(),
         {:ok, socket} <- SourceMonitor.join(socket, Session, &subscribe/0) do
      send(self(), :after_join)
      {:ok, assign(socket, :prefix, prefix)}
    else
      :error -> {:error, %{reason: "no stereo unit"}}
      {:error, reply} -> {:error, reply}
    end
  end

  @impl Phoenix.Channel
  def handle_cast({:stereo_calibration_changed, _prefix}, socket) do
    push_in_use(socket)
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    :ok = Outputs.subscribe(Calibration.changed_key(socket.assigns.prefix))
    push_session(socket, Session.state())
    push_in_use(socket)
    {:noreply, socket}
  end

  def handle_info({:calibration_session, state}, socket) do
    push_session(socket, state)
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  defp subscribe do
    {:ok, _state} = Session.subscribe()
    :ok
  end

  defp push_session(socket, state),
    do: push(socket, "session", CalibrationJSON.session(state, socket.assigns.prefix))

  defp push_in_use(socket) do
    with {:ok, config, _prefix} <- CalibrationUnit.fetch(),
         {:ok, in_use} <- Calibration.in_use(config) do
      push(socket, "in_use", CalibrationJSON.in_use(in_use))
    end

    :ok
  end
end
