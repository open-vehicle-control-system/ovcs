defmodule SimulatorCore.SimulatedComponents.OVCS.GenericController.DigitalPinRequest do
  @moduledoc """
  A generic controller's digital pin request, the frame the VMS switches
  relays and other digital outputs with. The simulated controller and
  the simulated parts wired to its pins read it through this module.
  Pure.
  """

  @pins 0..18

  @typedoc "The frame's decoded signals, as `handle_frame/4` receives them."
  @type signals :: %{String.t() => Cantastic.Signal.t()}

  @doc "The request frame of the controller whose frames start with `controller`."
  @spec frame_name(String.t()) :: String.t()
  def frame_name(controller), do: "#{controller}_digital_pin_request"

  @doc "The name of `pin`'s signal, in the request and in the controller's pin status."
  @spec signal_name(non_neg_integer()) :: String.t()
  def signal_name(pin), do: "digital_pin#{pin}_enabled"

  @doc "The names of every digital pin's signal."
  @spec signal_names() :: [String.t()]
  def signal_names, do: Enum.map(@pins, &signal_name/1)

  @doc "Whether the request enables `pin`. False when it does not carry the pin."
  @spec enabled?(signals(), non_neg_integer()) :: boolean()
  def enabled?(signals, pin) do
    signal = signal_name(pin)
    match?(%{^signal => %{value: true}}, signals)
  end

  @doc "What the request asks of each digital pin it carries, by signal name."
  @spec requested(signals()) :: %{String.t() => boolean()}
  def requested(signals) do
    for {name, signal} <- Map.take(signals, signal_names()), into: %{}, do: {name, signal.value}
  end
end
