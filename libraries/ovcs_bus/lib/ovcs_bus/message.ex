defmodule OvcsBus.Message do
  @moduledoc """
  A message travelling on `OvcsBus`.

  - `:name`          — short atom keying the semantic payload (`:ready_to_drive`, `:speed`).
  - `:value`         — the payload itself.
  - `:source`        — publishing module, used by subscribers to discriminate when
    multiple components emit messages under the same `:name`. Required and never
    `nil`: subscribers gate on `source == state.some_source`, and a component whose
    configured source is `nil` (a control level that commands nothing) must not
    match anything. `OvcsBus.broadcast/2` rejects a nil source.
  - `:unit`          — the unit of a physical `:value`, from `OvcsBus.Units`, or
    `nil` for states, flags and normalised requests. Set by the publisher, the
    one component that knows what its value measures.
  - `:relay_origin`  — `nil` for messages published locally, or the relay key
    (e.g. `:mqtt`) for messages that arrived from another node via a relay.
    Relays use it to avoid echoing traffic they themselves injected.
  """
  @enforce_keys [:name, :source]
  defstruct [:name, :value, :source, unit: nil, relay_origin: nil]

  @type t :: %__MODULE__{
          name: atom(),
          value: term(),
          source: module(),
          unit: String.t() | nil,
          relay_origin: atom() | nil
        }
end
