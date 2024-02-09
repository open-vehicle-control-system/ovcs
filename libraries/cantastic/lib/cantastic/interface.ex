defmodule Cantastic.Interface do
  alias Cantastic.{Util, CompiledFrameSpec, Receiver, Emitter}
  require Logger

  def configure_children(can_network_specs, manual_setup, frame_handler, config) do
    interface_specs = Enum.map(can_network_specs, fn (can_network_spec) ->
      [network_name, interface] = can_network_spec |> String.split(":")
      network_config            = config["canNetworks"][network_name]
      bitrate                   = network_config["bitrate"]
      {:ok, socket}             = initialize_socket(interface, bitrate, manual_setup)
      %{
        network_name: network_name,
        network_config: network_config,
        socket: socket
      }
    end)

    receivers = configure_receivers(interface_specs, frame_handler)
    emitters  = configure_emitters(interface_specs)
    receivers ++ emitters
  end

  def configure_receivers(interface_specs, frame_handler) do
    interface_specs
    |> Enum.map(fn (%{network_name: network_name, network_config: network_config, socket: socket}) ->
      process_name                  = receiver_process_name(network_name)
      compiled_received_frame_specs = compile_frame_specs(network_config["receivedFrames"], network_name)
      Supervisor.child_spec({Receiver, [process_name, network_name, socket, compiled_received_frame_specs, frame_handler]}, id: process_name)
    end)
  end

  def configure_emitters(interface_specs) do
    interface_specs
    |> Enum.map(fn (%{network_name: network_name, network_config: network_config, socket: socket}) ->
      (network_config["emittedFrames"] || %{})
      |> compile_frame_specs(network_name)
      |> Enum.map(fn({_frame_id, compiled_frame_spec}) ->
        arguments = %{
          socket: socket,
          network_name: network_name,
          process_name: emitter_process_name(network_name, compiled_frame_spec.name),
          compiled_frame_spec: compiled_frame_spec
        }
        Supervisor.child_spec({Emitter, arguments}, id: arguments.process_name)
      end)
    end)
    |> List.flatten
  end

  def initialize_socket(interface, bitrate, manual_setup) do
    :ok           = Util.setup_can_interface(interface, bitrate, manual_setup)
    Util.bind_socket(interface)
  end

  def receiver_process_name(network_name) do
    "Cantastic#{network_name |> String.capitalize()}Receiver" |> String.to_atom
  end

  def emitter_process_name(network_name, frame_name) do
    "Cantastic#{network_name |> String.capitalize()}#{frame_name |> String.capitalize()}Emitter" |> String.to_atom
  end

  # {800: name: "handbrakeStatus", signals: [{name: 'handbrakeEngaged', value: true, mapping: ....}, {name: 'handbrakeError': {value: true, ...}}]}
  defp compile_frame_specs(frame_specs, network_name) do
    frame_specs
    |> Enum.reduce(%{}, fn({frame_name, frame_spec}, compiled_frame_specs) ->
      {:ok, compiled_frame_spec} = CompiledFrameSpec.from_frame_spec(network_name, frame_name, frame_spec)
      compiled_frame_specs |> Map.put(compiled_frame_spec.id, compiled_frame_spec)
    end)
  end
end
