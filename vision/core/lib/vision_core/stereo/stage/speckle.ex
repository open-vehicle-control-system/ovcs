defmodule VisionCore.Stereo.Stage.Speckle do
  @moduledoc """
  Drops speckles, small islands of disparity that agree with nothing
  around them, on the device. A matched pixel is kept when at least
  `:min_support` of the 48 others in its 7x7 neighbourhood matched within
  `:max_diff` pixels of it; the others become unmatched. Isolated blobs
  smaller than about 4x4 lose their support, while surfaces keep theirs
  up to their corners. It plays the part of OpenCV's `filterSpeckles`,
  which labels connected regions instead, a poor fit for a GPU.

  ## Options

    * `:min_support` (`12`) — neighbours that must agree, 0 to 48.
    * `:max_diff` (`1.0`) — how close, in pixels, a neighbour must be.

  Both change while running.
  """
  @behaviour VisionCore.Stereo.NxStage

  @radius 3
  @neighbours (2 * @radius + 1) * (2 * @radius + 1) - 1

  @option_specs [
    min_support: %{
      type: :integer,
      range: {0, @neighbours},
      description:
        "Neighbours in the 7x7 window that must agree for a pixel to be kept; 0 turns the filter off"
    },
    max_diff: %{
      type: :double,
      range: {0, 8},
      description: "How close, in pixels, a neighbour's disparity must be to agree"
    }
  ]

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Drops small islands of disparity that agree with nothing around them."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    state = %{
      min_support: Keyword.get(opts, :min_support, 12),
      max_diff: Keyword.get(opts, :max_diff, 1.0)
    }

    with {:ok, state} <- validate(state, :min_support, state.min_support),
         do: validate(state, :max_diff, state.max_diff)
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:disparity]

  @impl VisionCore.Stereo.NxStage
  def params(state, _context), do: %{min_support: state.min_support, max_diff: state.max_diff}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    Map.put(
      tensors,
      :disparity,
      despeckle(tensors.disparity, params.min_support, params.max_diff)
    )
  end

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{min_support: state.min_support, max_diff: state.max_diff}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) when key in [:min_support, :max_diff],
    do: validate(state, key, value)

  defp validate(state, :min_support, value)
       when is_integer(value) and value >= 0 and value <= @neighbours,
       do: {:ok, %{state | min_support: value}}

  defp validate(state, :max_diff, value) when is_number(value) and value >= 0,
    do: {:ok, %{state | max_diff: value * 1.0}}

  defp validate(_state, key, value),
    do: {:error, "speckle #{key} out of range: #{inspect(value)}"}

  # One gather of all 48 neighbours, unmatched outside the image, compiles to one pass.
  defp despeckle(disparity, min_support, max_diff) do
    {height, width} = Nx.shape(disparity)
    padded_width = width + 2 * @radius

    flat =
      disparity
      |> Nx.pad(-1.0, [{@radius, @radius, 0}, {@radius, @radius, 0}])
      |> Nx.reshape({:auto, 1})

    offsets =
      for dy <- -@radius..@radius,
          dx <- -@radius..@radius,
          {dy, dx} != {0, 0},
          do: dy * padded_width + dx

    centres =
      Nx.iota({height, width, 1}, axis: 0)
      |> Nx.add(@radius)
      |> Nx.multiply(padded_width)
      |> Nx.add(Nx.add(Nx.iota({height, width, 1}, axis: 1), @radius))

    neighbours =
      flat
      |> Nx.gather(Nx.new_axis(Nx.add(centres, Nx.tensor([[offsets]], type: :s32)), -1))
      |> Nx.reshape({height, width, @neighbours})

    support =
      Nx.logical_and(
        Nx.greater_equal(neighbours, 0),
        Nx.less_equal(Nx.abs(Nx.subtract(neighbours, Nx.new_axis(disparity, -1))), max_diff)
      )
      |> Nx.sum(axes: [2])

    kept = Nx.logical_and(Nx.greater_equal(disparity, 0), Nx.greater_equal(support, min_support))
    Nx.select(kept, disparity, -1.0)
  end
end
