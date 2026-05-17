defmodule RadioControlBridge.ComponentsTest do
  use ExUnit.Case, async: true

  alias RadioControlBridge.Components
  alias RadioControlBridge.Config

  describe "Components.start/2 — :mavlink_forwarder" do
    test "returns a single RadioControlBridge.MavlinkForwarder child spec" do
      # The forwarder GenServer doesn't consume the UART opts itself
      # (ExpressLrs.Application gets them via runtime.exs); they're
      # accepted for completeness but unused at this layer.
      assert [{RadioControlBridge.MavlinkForwarder, nil}] =
               Components.start(:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800)
    end
  end

  describe "Components.start/2 — :msp_osd_forwarder" do
    test "returns a single RadioControlBridge.MspOsdForwarder child spec" do
      assert [{RadioControlBridge.MspOsdForwarder, nil}] =
               Components.start(:msp_osd_forwarder, [])
    end
  end

  test "Components.start/2 — unknown component raises FunctionClauseError" do
    assert_raise FunctionClauseError, fn -> Components.start(:not_a_component, []) end
  end

  describe "Config.component_opts/2" do
    test "returns the opts list for a tuple-form component" do
      config = %Config{
        components: [
          {:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}
        ]
      }

      opts = Config.component_opts(config, :mavlink_forwarder)
      assert opts[:uart_port] == "ttySC0"
      assert opts[:uart_baud_rate] == 460_800
    end

    test "returns [] for a bare-atom component" do
      config = %Config{components: [:msp_osd_forwarder]}
      assert Config.component_opts(config, :msp_osd_forwarder) == []
    end

    test "returns nil when the component isn't listed" do
      config = %Config{components: []}
      assert Config.component_opts(config, :mavlink_forwarder) == nil
    end
  end

  defmodule FakeVehicleWithMavlink do
    def radio_control_bridge_config(_arm) do
      %Config{
        components: [
          {:mavlink_forwarder, uart_port: "ttyTEST", uart_baud_rate: 921_600}
        ]
      }
    end
  end

  defmodule FakeVehicleWithoutMavlink do
    def radio_control_bridge_config(_arm), do: %Config{components: []}
  end

  describe "RadioControlBridge.apply_runtime_config/2" do
    setup do
      # Snapshot whatever :express_lrs env may already exist (other
      # tests, dev shell, etc.) so this test's writes don't leak.
      previous = Application.get_all_env(:express_lrs)
      on_exit(fn -> reset_express_lrs(previous) end)
      :ok
    end

    test "stamps :express_lrs env from the :mavlink_forwarder UART opts" do
      RadioControlBridge.apply_runtime_config(FakeVehicleWithMavlink, :target)

      assert Application.get_env(:express_lrs, :enabled) == true

      assert Application.get_env(:express_lrs, :interface) == %{
               uart_port: "ttyTEST",
               uart_baud_rate: 921_600
             }
    end

    test "is a no-op when :mavlink_forwarder isn't in the components list" do
      Application.delete_env(:express_lrs, :enabled)
      Application.delete_env(:express_lrs, :interface)

      RadioControlBridge.apply_runtime_config(FakeVehicleWithoutMavlink, :host)

      refute Application.get_env(:express_lrs, :enabled)
      refute Application.get_env(:express_lrs, :interface)
    end
  end

  defp reset_express_lrs(previous) do
    for {k, _v} <- Application.get_all_env(:express_lrs) do
      Application.delete_env(:express_lrs, k)
    end

    for {k, v} <- previous do
      Application.put_env(:express_lrs, k, v, persistent: true)
    end
  end
end
