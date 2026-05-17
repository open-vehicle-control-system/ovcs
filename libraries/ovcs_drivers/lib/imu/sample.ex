defmodule OvcsDrivers.Imu.Sample do
  @moduledoc """
  One sample produced by any module implementing `OvcsDrivers.Imu`,
  in SI units. Five kinds are defined; not every driver produces
  every kind (e.g. BNO085 currently emits acceleration, angular
  velocity, and rotation but not magnetometer or temperature). The
  kind field carries the discriminator and tells the consumer which
  of `x`/`y`/`z`/`w` to read:

  | kind                | units                 | fields used  |
  |---------------------|-----------------------|--------------|
  | `:acceleration`     | m/s²                  | x, y, z      |
  | `:angular_velocity` | rad/s                 | x, y, z      |
  | `:rotation`         | unit-quaternion       | x, y, z, w   |
  | `:magnetometer`     | tesla                 | x, y, z      |
  | `:temperature`      | kelvin                | x            |

  Unused fields are `nil`.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :x, :y, :z, :w]

  @type kind :: :acceleration | :angular_velocity | :rotation | :magnetometer | :temperature
  @type t :: %__MODULE__{
          kind: kind(),
          x: float() | nil,
          y: float() | nil,
          z: float() | nil,
          w: float() | nil
        }
end
