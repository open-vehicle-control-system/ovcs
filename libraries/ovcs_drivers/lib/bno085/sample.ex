defmodule BNO085.Sample do
  @moduledoc """
  One sample emitted by a `BNO085.*` driver, already converted from
  the chip's Q-point int16 representation to SI units. Hardware
  vocabulary only — no application-framework types here so the
  driver can eventually be lifted out into its own standalone
  library.

    * `:acceleration`     — m/s², three axes (x, y, z); w unused.
    * `:angular_velocity` — rad/s, three axes (x, y, z); w unused.
    * `:rotation`         — unit-quaternion components (x, y, z, w).

  The consuming application is responsible for shaping these into
  its own messages.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :x, :y, :z, :w]

  @type kind :: :acceleration | :angular_velocity | :rotation
  @type t :: %__MODULE__{kind: kind(), x: float() | nil, y: float() | nil, z: float() | nil, w: float() | nil}
end
