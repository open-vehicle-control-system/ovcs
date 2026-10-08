defmodule RosBridge.Consumers.Joy.Profile do
  @moduledoc """
  How one controller's `sensor_msgs/Joy` axes become the actuator
  command, read from a YAML file:

      # g923.yml: Logitech G923 in HID mode.
      device: G923 Racing Wheel
      steering:
        - axis: 0
          gain: -5.0
      throttle:
        - pedal: 1
        - pedal: 2
          gain: -1.0
      gears:
        forward: [12, 13, 14, 15, 16, 17]
        backward: [11]

  A profile is named after its file and reads `joy/<name>`. `device`
  is a regular expression matching the controller's name as the kernel
  reports it, which the operator's `joy` node uses to pick the profile
  of the controller plugged in (`compose/compute/images/ros2/docker/joy.sh`),
  with `deadzone`, if set, as its `joy_linux` deadzone, and `centring`,
  if set, as the strength (0 to 1) of the force-feedback spring it holds
  on the controller.
  `steering` and
  `throttle` are each the sum of their terms, clamped to [-1, 1], in
  the units of the `ros_actuator_command` frame: throttle drives when
  positive and brakes when negative, and steering is positive to the
  right on the OVCS Mini reference vehicle, against `joy_linux`
  reporting left as positive, hence the negative steering gains. A term
  reads one axis, times its `gain` (1.0):

    * `axis: i` — as `joy_linux` reports it, -1 to 1
    * `pedal: i` — a pedal reported -1 released and 1 pressed, read
      0 to 1

  `gears`, optional, selects the direction from what is held: `forward`
  and `backward` each list buttons (`button: i`, or the bare index) and
  triggers (`trigger: i`, an axis resting at 1 and pressed towards -1,
  held past half travel). A gear lever's positions are buttons held
  while it sits in them; a trigger is held by hand:

      gears:
        forward:
          - trigger: 5
        backward:
          - trigger: 2

  Nothing held, or both directions at once, is neutral, where the
  throttle cannot drive (it still brakes). Without `gears` the
  direction is always forward.

  A pedal reads as released until a sample has shown it released:
  `joy_linux` reports an axis it has no event for as 0, which is a
  pedal half pressed. A missing or non-numeric axis reads as 0.
  """

  defstruct [:name, :device, :gears, steering: [], throttle: []]

  @type term_spec :: {:axis | :pedal, non_neg_integer(), float()}
  @type t :: %__MODULE__{
          name: String.t(),
          device: String.t() | nil,
          steering: [term_spec()],
          throttle: [term_spec()],
          gears:
            nil
            | %{forward: [control()], backward: [control()]}
        }

  @type control :: {:button | :trigger, non_neg_integer()}
  @type direction :: :forward | :backward | :neutral

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

  @doc "The framework's profiles, in the bridge's `priv/joy`."
  @spec framework_dir() :: Path.t()
  def framework_dir, do: :ros_bridge |> :code.priv_dir() |> Path.join("joy")

  @doc "Every `*.yml` profile in `dir`."
  @spec load_dir!(Path.t()) :: [t()]
  def load_dir!(dir), do: dir |> Path.join("*.yml") |> Path.wildcard() |> Enum.map(&load!/1)

  @doc "A profile from its decoded YAML."
  @spec parse!(String.t(), map()) :: t()
  def parse!(name, yaml) do
    %__MODULE__{
      name: name,
      device: device!(name, Map.get(yaml, "device")),
      steering: terms!(name, yaml, "steering"),
      throttle: terms!(name, yaml, "throttle"),
      gears: gears!(name, Map.get(yaml, "gears"))
    }
  end

  defp device!(_name, nil), do: nil

  defp device!(name, device) when is_binary(device) do
    case Regex.compile(device) do
      {:ok, _} -> device
      {:error, error} -> raise ArgumentError, "joy profile #{name}, device: #{inspect(error)}"
    end
  end

  defp device!(name, device),
    do: raise(ArgumentError, "joy profile #{name}, device: not a string: #{inspect(device)}")

  @doc "The `Joy` topic a profile reads."
  @spec topic(t()) :: String.t()
  def topic(%__MODULE__{name: name}), do: "joy/#{name}"

  defp gears!(_name, nil), do: nil

  defp gears!(name, %{} = gears) do
    for direction <- ["forward", "backward"], into: %{} do
      controls = gears |> Map.get(direction, []) |> List.wrap()
      {String.to_atom(direction), Enum.map(controls, &control!(name, direction, &1))}
    end
  end

  defp gears!(name, gears),
    do: raise(ArgumentError, "joy profile #{name}, gears: not a map: #{inspect(gears)}")

  defp control!(_name, _direction, index) when is_integer(index) and index >= 0,
    do: {:button, index}

  defp control!(_name, _direction, %{"button" => index}) when is_integer(index) and index >= 0,
    do: {:button, index}

  defp control!(_name, _direction, %{"trigger" => index}) when is_integer(index) and index >= 0,
    do: {:trigger, index}

  defp control!(name, direction, control),
    do: raise(ArgumentError, "joy profile #{name}, gears: bad #{direction} #{inspect(control)}")

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

  @doc """
  The direction what is held in a sample asks for, `nil` without
  `gears`.
  """
  @spec direction(t(), [number()] | nil, [integer()] | nil) :: direction() | nil
  def direction(%__MODULE__{gears: nil}, _axes, _buttons), do: nil

  def direction(%__MODULE__{gears: gears}, axes, buttons) do
    held = &held?(&1, axes, buttons)

    case {Enum.any?(gears.forward, held), Enum.any?(gears.backward, held)} do
      {true, false} -> :forward
      {false, true} -> :backward
      _ -> :neutral
    end
  end

  defp held?({:button, index}, _axes, buttons) when is_list(buttons),
    do: Enum.at(buttons, index) == 1

  defp held?({:button, _index}, _axes, _buttons), do: false
  # Before its first event joy_linux reports a trigger as 0: not held.
  defp held?({:trigger, index}, axes, _buttons), do: axis(axes, index) <= -0.5

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
