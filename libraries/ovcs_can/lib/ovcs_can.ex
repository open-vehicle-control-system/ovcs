defmodule OvcsCan do
  @moduledoc """
  Shared OVCS CAN frame and signal definitions.

  This library only ships YAML data under `priv/can/`. Vehicle entry-point
  YAMLs live inside each consuming Elixir app (`vms/core`, `infotainment/core`)
  and reference shared component and vehicle-subcomponent definitions from
  here via Cantastic's `import!:@ovcs_can:...` syntax.
  """

  @doc "Absolute path to the library's `priv/can/` directory."
  def priv_can_path, do: Path.join(:code.priv_dir(:ovcs_can), "can")
end
