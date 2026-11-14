defmodule VisionApiWeb.CalibrationChannel do
  @moduledoc """
  Pushes the calibration session as `"session"` on join and on each change
  of `VisionCore.Calibration.Session`, with the id of the `calibration` it
  works on, and each calibration in use as `"calibration"`, with its `id`,
  on join and each time the unit takes another one; both shaped by
  `VisionApiWeb.CalibrationJSON`; a camera's pose as its own calibration,
  at each change of the pose. Each change of the calibrations kept
  for one of them, as one kept, renamed, removed or put in force, is
  pushed as `"saved"` with the id of that `calibration`: the client
  reads the `saved-calibrations` again. Joining subscribes to the session, which
  turns detection on in the core until the last subscriber leaves. The
  channel takes no push.

  Stops when the session restarts, and refuses the join while it is not
  running; see `VisionApiWeb.SourceMonitor`. A unit with nothing to
  calibrate refuses it with `%{reason: "nothing to calibrate"}`, which
  the client does not retry.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.{CalibrationJSON, CalibrationUnit, SourceMonitor}
  alias VisionCore.Calibration
  alias VisionCore.Calibration.{Recorder, Session}
  alias VisionCore.Outputs

  @impl Phoenix.Channel
  def join("calibration", _payload, socket) do
    with [_target | _others] = targets <- CalibrationUnit.targets(),
         {:ok, socket} <- SourceMonitor.join(socket, Session, &subscribe/0) do
      send(self(), :after_join)
      {:ok, assign(socket, :targets, targets)}
    else
      [] -> {:error, %{reason: "nothing to calibrate"}}
      {:error, reply} -> {:error, reply}
    end
  end

  @impl Phoenix.Channel
  def handle_in(_event, _payload, socket), do: VisionApiWeb.UnknownEvent.refuse(socket)

  @impl Phoenix.Channel
  def handle_cast({:stereo_calibration_changed, prefix}, socket) do
    push_calibration(socket, prefix)
    {:noreply, socket}
  end

  def handle_cast({:camera_calibration_changed, name}, socket) do
    push_calibration(socket, Atom.to_string(name))
    {:noreply, socket}
  end

  def handle_cast({:camera_pose_changed, name}, socket) do
    for %{kind: :pose, name: ^name, id: id} <- socket.assigns.targets,
        do: push_calibration(socket, id)

    {:noreply, socket}
  end

  def handle_cast({:saved_calibrations_changed, id}, socket) do
    push(socket, "saved", %{calibration: id})
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    for target <- socket.assigns.targets do
      :ok = Outputs.subscribe(Calibration.changed_key(target))
      :ok = Outputs.subscribe(Recorder.changed_key(target.id))
      push_calibration(socket, target.id)
    end

    push_session(socket, Session.state())
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

  defp push_session(socket, state) do
    session = CalibrationJSON.session(state)
    push(socket, "session", Map.put(session, :calibration, state.target && state.target.id))
  end

  defp push_calibration(socket, id) do
    with {:ok, in_use} <- Calibration.in_use(CalibrationUnit.config(), id),
         do: push(socket, "calibration", Map.put(CalibrationJSON.in_use(in_use), :id, id))

    :ok
  end
end
