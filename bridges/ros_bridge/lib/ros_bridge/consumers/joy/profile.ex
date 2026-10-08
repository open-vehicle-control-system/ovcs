defmodule RosBridge.Consumers.Joy.Profile do
  @moduledoc """
  How one controller's `sensor_msgs/Joy` axes become the actuator
  command, read from a YAML file:

      # Logitech G923 in HID mode.
      topic: joy_wheel
      steering:
        - axis: 0
          gain: -5.0
      throttle:
        - pedal: 1
        - pedal: 2
          gain: -1.0

  `topic` is the `Joy` topic the profile reads. `steering` and
  `throttle` are each the sum of their terms, clamped to [-1, 1], in
  the units of the `ros_actuator_command` frame. A term reads one axis,
  times its `gain` (1.0):

    * `axis: i` — as `joy_linux` reports it, -1 to 1
    * `pedal: i` — a pedal reported -1 released and 1 pressed, read
      0 to 1

  A pedal reads as released until a sample has shown it released:
  `joy_linux` reports an axis it has no event for as 0, which is a
  pedal half pressed. A missing or non-numeric axis reads as 0.
  """

  defstruct [:name, :topic, steering: [], throttle: []]

  @type term_spec :: {:axis | :pedal, non_neg_integer(), float()}
  @type t :: %__MODULE__{
          name: String.t(),
          topic: String.t(),
          steering: [term_spec()],
          throttle: [term_spec()]
        }

  @doc "The profile in `path`, named after the file."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    name = Path.basename(path, Path.extname(path))

    case YamlElixir.read_from_file(path) do
      {:ok, %{} = yaml} -> parse!(name, yaml)
      {:ok, other} -> raise ArgumentError, "joy profile #{path}: not a map: #{inspect(other)}"
      {:error, error} -> raise ArgumentError, "joy profile #{path}: #{Exception.message(error)}"
    end
  end

  @doc "Every `*.yml` profile in `dir`."
  @spec load_dir!(Path.t()) :: [t()]
  def load_dir!(dir), do: dir |> Path.join("*.yml") |> Path.wildcard() |> Enum.map(&load!/1)

  @doc "A profile from its decoded YAML."
  @spec parse!(String.t(), map()) :: t()
  def parse!(name, yaml) do
    %__MODULE__{
      name: name,
      topic: Map.get(yaml, "topic", "joy"),
      steering: terms!(name, yaml, "steering"),
      throttle: terms!(name, yaml, "throttle")
    }
  end

  defp terms!(name, yaml, output) do
    yaml |> Map.get(output, []) |> List.wrap() |> Enum.map(&term!(name, output, &1))
  end

  defp term!(_name, _output, %{"axis" => index} = term) when is_integer(index) and index >= 0,
    do: {:axis, index, gain(term)}

  defp term!(_name, _output, %{"pedal" => index} = term) when is_integer(index) and index >= 0,
    do: {:pedal, index, gain(term)}

  defp term!(name, output, term),
    do: raise(ArgumentError, "joy profile #{name}, #{output}: bad term #{inspect(term)}")

  defp gain(term), do: term |> Map.get("gain", 1.0) |> Kernel.*(1.0)

  @doc "The default: a gamepad on `joy`, axis 0 steering (inverted) and axis 1 throttle."
  @spec gamepad() :: t()
  def gamepad,
    do: %__MODULE__{
      name: "gamepad",
      topic: "joy",
      steering: [{:axis, 0, -1.0}],
      throttle: [{:axis, 1, 1.0}]
    }

  @doc """
  `{steering, throttle, released}` for a sample's `axes`, each in
  [-1, 1]. `released` is the set of pedal axes seen released so far,
  updated from this sample.
  """
  @spec command(t(), [number()] | nil, MapSet.t()) :: {float(), float(), MapSet.t()}
  def command(%__MODULE__{} = profile, axes, released \\ MapSet.new()) do
    released =
      for {:pedal, index, _} <- profile.steering ++ profile.throttle,
          axis(axes, index) <= -0.95,
          reduce: released,
          do: (acc -> MapSet.put(acc, index))

    {output(profile.steering, axes, released), output(profile.throttle, axes, released), released}
  end

  defp output(terms, axes, released) do
    terms
    |> Enum.reduce(0.0, fn {kind, index, gain}, sum ->
      sum + gain * read(kind, axes, index, released)
    end)
    |> clamp()
  end

  defp read(:axis, axes, index, _released), do: clamp(axis(axes, index))

  # -1 is released; a little travel is allowed for a worn pedal.
  defp read(:pedal, axes, index, released) do
    if MapSet.member?(released, index), do: (clamp(axis(axes, index)) + 1) / 2, else: 0.0
  end

  defp axis(axes, index) when is_list(axes), do: axes |> Enum.at(index) |> number()
  defp axis(_axes, _index), do: 0.0

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_other), do: 0.0

  defp clamp(value), do: value |> max(-1.0) |> min(1.0)
end
