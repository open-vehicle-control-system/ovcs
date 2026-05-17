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
end
