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

  `captured_at_ns` and `received_at_ns` use the local BEAM monotonic
  clock. Hardware drivers may estimate capture time from a polled
  transport; it is not a synchronized hardware timestamp. `accuracy`
  is the sensor's calibration status (0 unreliable through 3 high),
  not a covariance. `reference` identifies a continuous orientation
  reference and changes when the sensor resets. Metadata may be nil
  for drivers that cannot supply it. Unused fields are `nil`.
  """
  @enforce_keys [:kind]
  defstruct [
    :kind,
    :x,
    :y,
    :z,
    :w,
    :captured_at_ns,
    :received_at_ns,
    :accuracy,
    :sequence,
    :reference
  ]

  @type kind :: :acceleration | :angular_velocity | :rotation | :magnetometer | :temperature
  @type t :: %__MODULE__{
          kind: kind(),
          x: float() | nil,
          y: float() | nil,
          z: float() | nil,
          w: float() | nil,
          captured_at_ns: integer() | nil,
          received_at_ns: integer() | nil,
          accuracy: 0..3 | nil,
          sequence: integer() | nil,
          reference: reference() | nil
        }
end
