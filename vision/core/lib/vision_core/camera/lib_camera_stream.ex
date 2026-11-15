defmodule VisionCore.Camera.LibCameraStream do
  @moduledoc """
  `VisionCore.Camera` driver for a camera of its own made by a second
  stream of a stereo camera's libcamera capture: the ISP's second
  output of the stereo unit's left or right `VisionCore.Camera.LibCamera`,
  in the same request as its frames. The `:camera` component
  (`VisionCore.Components`) starts it, as `VisionCore.Camera.Unit`.

  The stereo side's driver owns the capture and makes the camera's
  outputs: `VisionCore.Components.wire_streams!/1` hands it the camera's
  `:outputs` and `:max_hz` as its `:outputs` and `:outputs_max_hz`, and
  the camera its side's `:side_label`. This driver subscribes to the
  side's output keys and publishes each frame under `{:camera_frame,
  name, output}`, `name` its registered name, with its own `:label` and
  `:frame_id`. The side's frames, under its own key, are the stereo
  unit's alone.

  The sensor's controls stay the stereo unit's (`stereo.cameras.*`), so
  the camera has no controls, no parameter group and no `live/1`.

  When the stereo unit restarts or gives up, the stream stops with its
  capture: this driver stays up, its subscriptions held
  (`VisionCore.Outputs`), and `running?/1` answers `false` until the
  side's capture runs again. A restart of this camera leaves the stereo
  unit untouched.

  ## Opts

    * `:label` (required) — the camera's name as text, which its frames
      carry and it registers by (`name_for/1`).
    * `:frame_id` — the optical frame its frames carry.
    * `:stream_of` — `:left` or `:right`, the stereo side whose capture
      makes it.
    * `:outputs` (required) — the camera's named outputs
      (`VisionCore.Camera.Output`): one made by the processor `:isp` at
      an even size, with `send: false`, and JPEGs made `:from` it at its
      size, the first sent the camera's default.
    * `:max_hz` — the most frames a second its outputs are made on;
      every frame without it.
    * `:side_label` (required) — the label of the side's driver, which
      the wiring gives.
  """
  use GenServer

  @behaviour VisionCore.Camera

  alias VisionCore.Camera.{LibCamera, Output}
  alias VisionCore.Outputs

  def start_link(opts) do
    label = Keyword.fetch!(opts, :label)
    GenServer.start_link(__MODULE__, opts, name: name_for(label))
  end

  @doc "The registered name of the driver for `label`."
  @impl VisionCore.Camera
  def name_for(label), do: Module.concat([__MODULE__, "L_#{label}"])

  @doc """
  The camera's outputs from `opts`, its `:outputs` resolved for the
  processor `:isp` and the formats RGB and JPEG
  (`VisionCore.Camera.LibCamera.resolve_isp_outputs/1`); `{:error,
  message}` without them or for outputs that cannot be made. The side's
  sensor mode bounds the ISP output's size, which the wiring checks
  (`VisionCore.Camera.LibCamera.capture_outputs/1`).
  """
  @impl VisionCore.Camera
  def outputs(opts) do
    case Keyword.fetch(opts, :outputs) do
      {:ok, outputs} ->
        LibCamera.resolve_isp_outputs(outputs)

      :error ->
        {:error, "it names its :outputs, which the stereo side's capture makes"}
    end
  end

  @doc "Whether the stereo side's capture program runs: `false` while its driver is down."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server), do: GenServer.call(server, :running?)

  @impl GenServer
  def init(opts) do
    label = Keyword.fetch!(opts, :label)

    side_label =
      Keyword.get_lazy(opts, :side_label, fn ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}[#{label}] needs its stereo side's :side_label, " <>
                "which VisionCore.Components.wire_streams!/1 gives"
      end)

    {:ok, outputs} = outputs(opts)
    side = LibCamera.name_for(side_label)

    keys =
      for %Output{name: output} <- Output.sent(outputs), into: %{} do
        :ok = Outputs.subscribe({:camera_frame, side, output})
        {output, {:camera_frame, name_for(label), output}}
      end

    {:ok, %{label: label, frame_id: Keyword.get(opts, :frame_id), side: side, keys: keys}}
  end

  @impl GenServer
  def handle_cast({:camera_frame, frame}, state) do
    Outputs.publish(
      Map.fetch!(state.keys, frame.output),
      {:camera_frame, %{frame | label: state.label, frame_id: state.frame_id}}
    )

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, side_running?(state.side), state}

  defp side_running?(side) do
    GenServer.whereis(side) != nil and LibCamera.running?(side)
  catch
    # The side's driver stopped between the lookup and the call.
    :exit, _reason -> false
  end
end
