defmodule VisionCore.Camera.ParametersTest do
  # The registry and its store are named processes.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias VisionCore.Camera.{Parameters, Unit, V4L2Single}
  alias VisionCore.Parameters.MemoryStore

  # A camera holding V4L2Single's controls, recording what it is sent.
  defmodule Driver do
    use Agent

    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)
    def name_for(label), do: label
    def control_specs, do: VisionCore.Camera.V4L2Single.control_specs()
    def controls("center"), do: Agent.get(__MODULE__, & &1.controls)
    def live("center"), do: Agent.get(__MODULE__, & &1.live)

    def set_controls("center", controls) do
      Agent.update(__MODULE__, &%{&1 | controls: Map.merge(&1.controls, Map.new(controls))})
      {:ok, controls("center")}
    end
  end

  # A camera with a gain and no automatic mode to set it.
  defmodule ManualDriver do
    def name_for(label), do: label

    def control_specs,
      do: [%{key: :analogue_gain, type: :double, range: {1, 16}, description: "Analogue gain"}]

    def controls("usb"), do: %{analogue_gain: 2.0}
    def set_controls("usb", _controls), do: {:ok, controls("usb")}
  end

  # A driver the camera unit starts, with one control.
  defmodule ControlledDriver do
    def name_for(label), do: Module.concat(__MODULE__, label)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(opts) do
      Agent.start_link(fn -> %{gamma: 2.2} end, name: name_for(Keyword.fetch!(opts, :label)))
    end

    def control_specs,
      do: [%{key: :gamma, type: :double, range: {0.5, 4}, description: "Gamma"}]

    def controls(server), do: Agent.get(server, & &1)

    def set_controls(server, controls),
      do: {:ok, Agent.update(server, &Map.merge(&1, Map.new(controls)))}

    def fixed_settings(opts), do: [fps: Keyword.fetch!(opts, :fps)]
  end

  @controls V4L2Single.control_specs()
            |> Map.new(&{&1.key, &1.default})
            |> Map.put(:threads, 3)

  setup do
    start_supervised!({Driver, %{controls: @controls, live: nil}})
    :ok
  end

  defp group(opts \\ []),
    do: Parameters.group(Keyword.merge([name: :center, driver: Driver], opts))

  defp parameter(group, name), do: Enum.find(group.parameters, &(&1.name == name))

  test "a camera's group is a component of a pipeline of its name, between the stereo and the inference steps" do
    group = group()

    assert %{id: "center.camera", name: "Camera", kind: :component, pipeline: :center} = group
    assert group.position > 9 and group.position < 101
  end

  test "lists each control of its driver, live, with its type and range" do
    group = group()

    assert Enum.map(group.parameters, & &1.name) ==
             Enum.map(V4L2Single.control_specs(), &Atom.to_string(&1.key))

    assert %{type: :double, applies: :live, constraint: %{kind: :range, min: 1, max: 254}} =
             parameter(group, "target_brightness")

    assert %{type: :bool, applies: :live} = parameter(group, "ccm")
    assert parameter(group, "rotation").constraint == %{kind: :choices, values: [0, 180]}
    assert parameter(group, "threads").get.() == 3
  end

  test "exposure and gain are set by auto exposure, the colour gains by the white balance" do
    group = group()

    for name <- ["exposure_us", "analogue_gain"],
        do: assert(parameter(group, name).applies == {:auto, "center.camera.auto_exposure"})

    for name <- ["red_gain", "blue_gain"],
        do: assert(parameter(group, name).applies == {:auto, "center.camera.awb"})
  end

  test "exposure and gain read what the sensor applies while auto exposure runs, and default to the manual settings" do
    Agent.update(Driver, &%{&1 | live: %{exposure_time_us: 12_000, analogue_gain: 4.0}})
    group = group()

    assert parameter(group, "exposure_us").get.() == 12_000
    assert parameter(group, "exposure_us").default == 8_000
    assert parameter(group, "analogue_gain").get.() == 4.0
    assert parameter(group, "analogue_gain").default == 2.0
  end

  test "the colour gains read what the white balance applies while it runs, and the manual gains once it is off" do
    Agent.update(Driver, &%{&1 | live: %{red_gain: 2.54, blue_gain: 1.94}})
    group = group()

    assert parameter(group, "red_gain").get.() == 2.54
    assert parameter(group, "blue_gain").get.() == 1.94

    Agent.update(Driver, &put_in(&1.controls.awb, false))

    assert parameter(group, "red_gain").get.() == 1.0
    assert parameter(group, "blue_gain").get.() == 1.0
  end

  test "a control whose automatic mode its driver does not have is live" do
    gain = parameter(group(name: :usb, driver: ManualDriver), "analogue_gain")

    assert gain.applies == :live
    assert gain.get.() == 2.0
  end

  test "lists the settings fixed at start after the controls, read-only" do
    group = group(fixed: [fps: 30, sensor_mode: {2028, 1520}])

    assert %{applies: :build, type: :integer} = fps = parameter(group, "fps")
    assert fps.get.() == 30
    assert parameter(group, "sensor_mode").get.() == "2028x1520"
    assert List.last(group.parameters).name == "sensor_mode"
  end

  describe "started" do
    setup context do
      start_supervised!({MemoryStore, context[:saved] || %{}})
      start_supervised!({VisionCore.Parameters, store: MemoryStore})
      start_supervised!({Parameters, name: :center, driver: Driver})
      # Waits for the registry to finish applying the declaration.
      :sys.get_state(VisionCore.Parameters)
      :ok
    end

    test "declares the camera's group, and a control set through it reaches the driver" do
      assert [%{id: "center.camera"}] = VisionCore.Parameters.groups()

      assert {:ok, %{value: 1.8}} = VisionCore.Parameters.set("center.camera.gamma", 1.8)
      assert Driver.controls("center").gamma == 1.8
    end

    @tag saved: %{"center.camera.max_exposure_us" => 25_000}
    test "gives the camera its saved values" do
      assert Driver.controls("center").max_exposure_us == 25_000
    end

    test "a colour gain is refused while the white balance sets it, and taken once it is off" do
      assert {:error, "set by center.camera.awb while it is on"} =
               VisionCore.Parameters.set("center.camera.red_gain", 2.0)

      assert {:ok, _parameter} = VisionCore.Parameters.set("center.camera.awb", false)
      assert {:ok, %{value: 2.0}} = VisionCore.Parameters.set("center.camera.red_gain", 2.0)
      assert Driver.controls("center").red_gain == 2.0
    end

    test "switching the white balance off keeps the gains it applied" do
      Agent.update(Driver, &%{&1 | live: %{red_gain: 2.54, blue_gain: 1.94}})

      assert {:ok, _parameter} = VisionCore.Parameters.set("center.camera.awb", false)

      assert %{awb: false, red_gain: 2.54, blue_gain: 1.94} = Driver.controls("center")
      assert {:ok, %{value: 2.54}} = VisionCore.Parameters.get("center.camera.red_gain")
    end
  end

  test "a driver with runtime controls gets its parameters, started after it, with its fixed settings" do
    start_supervised!({VisionCore.Parameters, store: MemoryStore})
    unit = start_supervised!({Unit, name: :hq, driver: ControlledDriver, fps: 15})

    assert unit |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) == [
             VisionCore.Camera.Parameters,
             ControlledDriver
           ]

    assert [%{id: "hq.camera", parameters: parameters}] = VisionCore.Parameters.groups()
    assert Enum.map(parameters, &{&1.name, &1.value}) == [{"gamma", 2.2}, {"fps", 15}]
  end

  test "starts without a registry" do
    assert {:ok, _pid} = start_supervised({Parameters, name: :center, driver: Driver})
  end
end
