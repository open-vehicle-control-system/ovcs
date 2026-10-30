defmodule VisionCore.Ros2.ParametersTest do
  use ExUnit.Case, async: true

  import Ros2Zenoh.Cdr
  alias Ros2Zenoh.RclInterfaces.Parameters, as: Codec
  alias VisionCore.Parameters.Parameter
  alias VisionCore.Ros2.Parameters

  # A ParameterValue as ROS clients send it: every field present.
  defp encode_parameter(encoded, {name, type, bool, integer, double, string}) do
    encoded
    |> string(name)
    |> u8(Codec.type_id(type))
    |> bool(bool)
    |> i64(integer)
    |> f64(double)
    |> string(string)
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
    |> sequence([], & &1)
  end

  describe "the codec" do
    test "names the six services and their ROS types" do
      assert Enum.map(Codec.services(), fn {service, module} -> {service, module.dds_type()} end) ==
               [
                 {"list_parameters", "rcl_interfaces::srv::dds_::ListParameters_"},
                 {"get_parameters", "rcl_interfaces::srv::dds_::GetParameters_"},
                 {"get_parameter_types", "rcl_interfaces::srv::dds_::GetParameterTypes_"},
                 {"describe_parameters", "rcl_interfaces::srv::dds_::DescribeParameters_"},
                 {"set_parameters", "rcl_interfaces::srv::dds_::SetParameters_"},
                 {"set_parameters_atomically",
                  "rcl_interfaces::srv::dds_::SetParametersAtomically_"}
               ]
    end

    test "reads the parameters of a set request, aligned after strings of any length" do
      payload =
        sequence(
          <<>>,
          [{"a", :double, false, 0, 1.5, ""}, {"stereo.mode", :string, false, 0, 0.0, "short"}],
          &encode_parameter/2
        )

      assert Codec.decode_parameters(payload) == [{"a", 1.5}, {"stereo.mode", "short"}]
    end

    test "reads the names of a get request" do
      assert Codec.decode_names(sequence(<<>>, ["x", "stereo.left.lens_position"], &string/2)) ==
               ["x", "stereo.left.lens_position"]
    end

    test "writes values that read back with their types" do
      encoded = Codec.encode_values([{:integer, 20}, nil, {:bool, true}])
      {[integer_value, unset_value, bool_value], _} = read_sequence({encoded, 0}, &read_value/1)
      assert integer_value == {2, 20}
      assert unset_value == {0, nil}
      assert bool_value == {1, true}
    end
  end

  # Enough of a ParameterValue to check what was written.
  defp read_value(input) do
    {type, input} = read_u8(input)
    {bool, input} = read_bool(input)
    {integer, input} = read_i64(input)
    {_double, input} = read_f64(input)
    {_string, input} = read_string(input)
    input = Enum.reduce(1..5, input, fn _, input -> elem(read_sequence(input, &read_u8/1), 1) end)
    {{type, Enum.at([nil, bool, integer], type)}, input}
  end

  describe "the ROS view of a parameter" do
    defp parameter(fields) do
      struct(
        %Parameter{
          group: "stereo.match",
          type: :integer,
          applies: :live,
          constraint: %{kind: :range, min: 1, max: 79, step: nil},
          default: 64,
          value: 64,
          state: :builtin
        },
        fields
      )
    end

    test "describes a range parameter with its range, default and relation" do
      p2 = parameter(id: "stereo.match.p2", name: "p2", greater_than: "stereo.match.p1")

      assert %{
               name: "stereo.match.p2",
               type: :integer,
               read_only: false,
               range: {1, 79},
               constraints: "above stereo.match.p1; default: 64"
             } = Parameters.describe(p2)
    end

    test "gives a double's range as floats" do
      gain =
        parameter(
          id: "stereo.cameras.analogue_gain",
          type: :double,
          constraint: %{kind: :range, min: 1, max: 16, step: nil},
          default: 1.0
        )

      assert %{range: {1.0, 16.0}} = Parameters.describe(gain)
    end

    test "describes a choice parameter with its values" do
      rotation =
        parameter(
          id: "stereo.left.rotation",
          constraint: %{kind: :choices, values: [0, 180]},
          default: 0
        )

      description = Parameters.describe(rotation)
      assert description.constraints =~ "one of: 0, 180"
      refute Map.has_key?(description, :range)
    end

    test "gives no default outside the accepted values" do
      noise =
        parameter(
          id: "stereo.left.noise_reduction",
          type: :string,
          constraint: %{kind: :choices, values: ~w(off fast)},
          default: "auto"
        )

      assert Parameters.describe(noise).constraints == "one of: off, fast"
    end

    test "describes a build parameter as read-only" do
      width =
        parameter(id: "stereo.cameras.width", applies: :build, constraint: nil, default: 768)

      assert %{read_only: true, constraints: ""} = Parameters.describe(width)
    end

    test "describes an automatic parameter with what sets it" do
      exposure =
        parameter(
          id: "stereo.cameras.exposure",
          applies: {:auto, "stereo.cameras.auto_exposure"},
          state: :automatic
        )

      description = Parameters.describe(exposure)
      assert description.read_only == false
      assert description.constraints =~ "set by stereo.cameras.auto_exposure while it is on"
    end

    test "gives a value with its type, nil when unread" do
      assert Parameters.ros_value(parameter(value: 12)) == {:integer, 12}
      assert Parameters.ros_value(parameter(type: :double, value: 2)) == {:double, 2.0}
      assert Parameters.ros_value(parameter(value: nil)) == nil
    end
  end

  defmodule NoStore do
    @moduledoc false
    def load, do: %{}
    def write(_changes), do: :ok
  end

  describe "requests" do
    setup context do
      registry = :"#{__MODULE__}.#{context.test}"
      start_supervised!({VisionCore.Parameters, name: registry, store: NoStore})
      gain = start_supervised!({Agent, fn -> 2 end})

      :ok =
        VisionCore.Parameters.declare(registry, [
          %{
            id: "test.group",
            name: "Test",
            summary: "A test group.",
            kind: :component,
            placement: :side,
            position: 0,
            parameters: [
              %{
                name: "gain",
                type: :integer,
                get: fn -> Agent.get(gain, & &1) end,
                set: fn value -> Agent.update(gain, fn _ -> value end) end,
                constraint: %{kind: :range, min: 1, max: 10, step: nil}
              }
            ]
          }
        ])

      %{registry: registry, gain: gain}
    end

    @tag :capture_log
    test "a set request is a registry set", %{registry: registry, gain: gain} do
      payload =
        sequence(
          <<>>,
          [
            {"test.group.gain", :integer, false, 7, 0.0, ""},
            {"nope", :integer, false, 1, 0.0, ""}
          ],
          &encode_parameter/2
        )

      {results, _rest} =
        read_sequence({Parameters.respond("set_parameters", payload, registry), 0}, fn input ->
          {successful, input} = read_bool(input)
          {reason, input} = read_string(input)
          {{successful, reason}, input}
        end)

      assert results == [{true, ""}, {false, "unknown parameter"}]
      assert Agent.get(gain, & &1) == 7

      assert {:ok, %{value: 7, state: :unsaved}} =
               VisionCore.Parameters.get(registry, "test.group.gain")
    end

    test "lists the registry's ids", %{registry: registry} do
      {names, _rest} =
        read_sequence({Parameters.respond("list_parameters", <<>>, registry), 0}, &read_string/1)

      assert names == ["test.group.gain"]
    end
  end
end
