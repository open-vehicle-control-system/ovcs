defmodule VisionCore.Segmentation.Backend do
  @moduledoc """
  What a segmentation backend has to do, so
  `VisionCore.Segmentation.Pipeline` does not care which one it is
  talking to:

    * `VisionCore.Segmentation.Backend.Qnn` — a segmentation model on a
      Qualcomm Hexagon NPU, through the `qnn_segment` Port.
    * `VisionCore.Segmentation.Backend.Stub` — a fixed label image, no
      model. For proving the plumbing without an accelerator.

  ## The contract

  `segment/3` is asynchronous and lossy, as
  `VisionCore.Detection.Backend.detect/3` is: it hands a band of an
  image over and returns at once, `{:error, :busy}` while another is in
  flight, and the label image arrives later as

      {:inference_labels, sequence, labels}

  `labels` being `%{width:, height:, data:}`, `width * height` class ids,
  one byte each, row by row, the model's output grid stretched over the
  whole band, or `nil` when the backend could not segment that band. A
  band accepted gets exactly one reply, a band lost to the backend's own
  failure included.

  A backend that cannot work starts anyway, logs once and answers
  `{:error, :unavailable}`; `available?/1`, `npu_kind/0` and
  `inference_times/1` are `VisionCore.Detection.Backend`'s, so
  `VisionCore.Status` counts both kinds of backends alike.

  A backend registers under its `:name` option, declares the inference
  step of its `:pipeline` in `VisionCore.Parameters`
  (`VisionCore.Segmentation.inference_group/2`), and is given
  `:classes`, the number of classes the pipeline names: a backend
  running a model refuses one scoring another number.
  """

  @typedoc """
  A band of an image: `width * height * 3` bytes of 8-bit red, green and
  blue, row by row.
  """
  @type band :: %{width: pos_integer(), height: pos_integer(), rgb: binary()}

  @typedoc "One class id per cell of the model's output grid, row by row."
  @type labels :: %{width: pos_integer(), height: pos_integer(), data: binary()}

  @doc """
  Submit `band` for segmentation, tagged with `sequence`: `:ok` when
  accepted, a reply following; `{:error, :busy}` while one is in flight;
  `{:error, :unavailable}` when the backend is not working.
  """
  @callback segment(GenServer.server(), sequence :: non_neg_integer(), band()) ::
              :ok | {:error, :busy | :unavailable}

  @doc "False when the backend could not initialise. Never raises."
  @callback available?(GenServer.server()) :: boolean()

  @doc """
  Where the backend is: `:starting` while it prepares its model and
  opens its accelerator, `:running` once it takes bands, `:failed` when it
  does not and is not about to. Never raises. Without it,
  `available?/1` tells `:running` from `:failed`.
  """
  @callback state(GenServer.server()) :: :starting | :running | :failed

  @optional_callbacks state: 1

  @doc """
  The options the backend takes beside `:name` and those its unit's
  supervisor gives it: the supervisor hands it these of the unit's
  options, and refuses the unit one that neither it nor the backend
  takes.
  """
  @callback options() :: [atom()]

  @doc "The kind of accelerator the backend runs on, `nil` without one."
  @callback npu_kind() :: String.t() | nil

  @doc """
  The inference times, in microseconds, of the bands answered since the
  last call: their sum and their count. Starts them again.
  """
  @callback inference_times(GenServer.server()) ::
              %{sum_us: non_neg_integer(), count: non_neg_integer()} | nil
end
