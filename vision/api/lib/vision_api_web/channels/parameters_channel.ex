defmodule VisionApiWeb.ParametersChannel do
  @moduledoc """
  Pushes the vision parameters as `"stages"`, the document of
  `GET /api/stages?include=parameters` (`VisionApiWeb.StageJSON`):

    * every stage, `meta.complete` true with `meta.unsaved`, on join and
      each time `VisionCore.Parameters` publishes its listing, after a
      change it made;
    * the stages whose listing changed on their own, a status or a
      parameter set automatically, `meta.complete` false, without
      `meta.unsaved`: the client replaces those stages and their
      parameters only.

  Parameters are set, saved, discarded and reset through the API's
  requests; the channel takes no push. Stops when the registry restarts,
  and refuses the join while it is not running; see
  `VisionApiWeb.SourceMonitor`.
  """
  use VisionApiWeb, :channel

  alias VisionApiWeb.{SourceMonitor, StageJSON}
  alias VisionCore.{Outputs, Parameters}

  @impl Phoenix.Channel
  def join("parameters", _payload, socket) do
    with {:ok, socket} <- SourceMonitor.join(socket, Parameters, &subscribe/0) do
      send(self(), :after_join)
      {:ok, socket}
    end
  end

  defp subscribe, do: Outputs.subscribe(Parameters.changes_key())

  @impl Phoenix.Channel
  def handle_in(_event, _payload, socket), do: VisionApiWeb.UnknownEvent.refuse(socket)

  @impl Phoenix.Channel
  def handle_cast({:parameter_groups, :all, groups}, socket) do
    push_all(socket, groups)
    {:noreply, socket}
  end

  def handle_cast({:parameter_groups, :changed, groups}, socket) do
    document = StageJSON.index(%{groups: groups, include_parameters: true})
    push(socket, "stages", %{document | meta: %{complete: false}})
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    push_all(socket, Parameters.groups())
    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, socket),
    do: SourceMonitor.handle_down(monitor_reference, socket)

  defp push_all(socket, groups) do
    document = StageJSON.index(%{groups: groups, include_parameters: true})
    push(socket, "stages", put_in(document.meta[:complete], true))
  end
end
