defmodule RosBridge.ParametersTest do
  use ExUnit.Case, async: true

  import Ros2.Cdr
  alias Ros2.RclInterfaces.Parameters, as: Codec
  alias RosBridge.Parameters

  # A ParameterValue as ROS clients send it: every field present.
  defp parameter(acc, {name, type, bool, integer, double, string}) do
    acc
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
          &parameter/2
        )

      assert Codec.decode_parameters(payload) == [{"a", 1.5}, {"stereo.mode", "short"}]
    end

    test "reads the names of a get request" do
      assert Codec.decode_names(sequence(<<>>, ["x", "stereo.left.lens_position"], &string/2)) ==
               ["x", "stereo.left.lens_position"]
    end

    test "writes values that read back with their types" do
      encoded = Codec.encode_values([{:integer, 20}, nil, {:bool, true}])
      {[first, second, third], _} = read_sequence({encoded, 0}, &read_value/1)
      assert first == {2, 20}
      assert second == {0, nil}
      assert third == {1, true}
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

  describe "set/2" do
    defp gain, do: %{type: :double, range: {0, 16}, set: fn _ -> :ok end}

    test "applies a value that passes the checks, an integer as a double" do
      assert Parameters.set(gain(), 2) == {:ok, 2.0}
    end

    test "refuses unknown, read-only, mistyped and out-of-range values" do
      assert Parameters.set(nil, 1) == {:error, "unknown parameter"}

      assert {:error, "read-only" <> _} =
               Parameters.set(%{gain() | set: nil} |> Map.put(:read_only, true), 1.0)

      assert {:error, "expected double" <> _} = Parameters.set(gain(), "loud")
      assert {:error, "out of range 0..16"} = Parameters.set(gain(), 17)
    end

    test "checks a string against its accepted values" do
      mode = %{type: :string, values: ~w(normal short), set: fn _ -> :ok end}
      assert Parameters.set(mode, "short") == {:ok, "short"}
      assert {:error, "expected one of normal, short"} = Parameters.set(mode, "fast")
    end

    test "reports why the owner refused" do
      refusing = %{gain() | set: fn _ -> {:error, "camera busy"} end}
      assert Parameters.set(refusing, 1.0) == {:error, "camera busy"}
    end
  end
end
