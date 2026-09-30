defmodule VmsCore.Components.Matek.PM12S3 do
  @moduledoc """
  Battery voltage and current from a Matek PM12S-3 power module, read on
  a generic controller's analog inputs.

  The module's `Volt` pad is its battery input behind a 1K:20K divider,
  so the battery voltage is 21 times the pad's. Its `Curr` pad passes
  through the signal of whatever current sensor feeds it: the module has
  none of its own. That sensor's datasheet gives its scale and offset:

      current = (pad_voltage - current_offset) / current_scale

  The controller reads its analog inputs at 14 bits against its 5 V
  supply, so both pads must stay below 5 V and share its ground.

  `:voltage` and `:current` go out once per controller loop, and are nil
  while the controller is not alive: its last reading is not a live one.

  ## Options

    * `:controller` — the generic controller the pads are wired to.
    * `:voltage_pin` — its analog pin carrying `Volt` (0 to 2).
    * `:current_pin` — its analog pin carrying `Curr`; omit it to read
      the voltage only.
    * `:current_scale` — the sensor's output in volts per ampere.
    * `:current_offset` — the sensor's output at zero current, in volts.
      Defaults to 0.
    * `:voltage_divider` — defaults to 21, the module's; set it from a
      multimeter reading to correct the supply's tolerance.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias OvcsBus.Units

  @adc_max D.new(16_383)
  @adc_reference_voltage D.new(5)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{controller: controller, voltage_pin: voltage_pin} = args) do
    Bus.subscribe("messages")
    current_pin = Map.get(args, :current_pin)

    {:ok,
     %{
       controller: controller,
       voltage_name: pin_name(voltage_pin),
       current_name: current_pin && pin_name(current_pin),
       voltage_divider: D.new(Map.get(args, :voltage_divider, 21)),
       current_scale: current_pin && D.new(Map.fetch!(args, :current_scale)),
       current_offset: D.new(Map.get(args, :current_offset, 0)),
       raw_voltage: nil,
       raw_current: nil
     }}
  end

  @impl true
  def handle_info(%Bus.Message{name: name, value: raw, source: source}, state)
      when source == state.controller and name == state.voltage_name do
    {:noreply, %{state | raw_voltage: raw}}
  end

  def handle_info(%Bus.Message{name: name, value: raw, source: source}, state)
      when source == state.controller and name == state.current_name do
    {:noreply, %{state | raw_current: raw}}
  end

  # The controller publishes `:is_alive` after its pins, so this closes
  # each of its loops.
  def handle_info(%Bus.Message{name: :is_alive, value: alive, source: source}, state)
      when source == state.controller do
    voltage = if alive, do: voltage(state.raw_voltage, state.voltage_divider)
    broadcast(:voltage, voltage, Units.volt())

    if state.current_name do
      current =
        if alive, do: current(state.raw_current, state.current_scale, state.current_offset)

      broadcast(:current, current, Units.ampere())
    end

    {:noreply, state}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  @doc false
  def voltage(nil, _divider), do: nil

  def voltage(raw, divider) do
    raw |> pad_voltage() |> D.mult(divider) |> D.round(2)
  end

  @doc false
  def current(nil, _scale, _offset), do: nil

  def current(raw, scale, offset) do
    raw |> pad_voltage() |> D.sub(offset) |> D.div(scale) |> D.round(1)
  end

  defp pad_voltage(raw), do: raw |> D.new() |> D.mult(@adc_reference_voltage) |> D.div(@adc_max)

  defp pin_name(pin), do: :"received_analog_pin#{pin}_value"

  defp broadcast(name, value, unit) do
    Bus.broadcast("messages", %Bus.Message{
      name: name,
      value: value,
      unit: unit,
      source: __MODULE__
    })
  end
end
