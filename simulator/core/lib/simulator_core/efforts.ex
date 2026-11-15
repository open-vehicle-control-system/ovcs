defmodule SimulatorCore.Efforts do
  @moduledoc """
  What the simulated actuators ask of the vehicle in one tick, as a
  world's dynamics model takes it. Pure.

    * `drive_torque_nm` — at the driven wheels, signed, positive
      forward: a motor's torque through its reduction;
    * `brake_torque_nm` — at the wheels, a magnitude: it opposes their
      spin and holds them at standstill;
    * `steering_rad` — the front wheels' bicycle-equivalent angle,
      REP-103: positive turns left;
    * `driveline_inertia_kg_m2` — the motor's and gearbox's inertia at
      the driven wheels, which the drive torque also turns.
  """

  defstruct drive_torque_nm: 0.0,
            brake_torque_nm: 0.0,
            steering_rad: 0.0,
            driveline_inertia_kg_m2: 0.0

  @type t :: %__MODULE__{
          drive_torque_nm: float(),
          brake_torque_nm: float(),
          steering_rad: float(),
          driveline_inertia_kg_m2: float()
        }

  @typedoc "One simulated actuator's contribution to the tick's efforts."
  @type actuation ::
          {:drive_torque_nm, float()}
          | {:brake_torque_nm, float()}
          | {:steering_rad, float()}
          | {:driveline_inertia_kg_m2, float()}

  @doc """
  The tick's efforts from every actuator's: torques and inertias add, a
  brake as a magnitude, and the last steering wins, `previous_steering_rad`
  when none steers.
  """
  @spec combine([actuation()], float()) :: t()
  def combine(actuations, previous_steering_rad) do
    Enum.reduce(actuations, %__MODULE__{steering_rad: previous_steering_rad}, fn
      {:drive_torque_nm, torque}, efforts ->
        %{efforts | drive_torque_nm: efforts.drive_torque_nm + torque}

      {:brake_torque_nm, torque}, efforts ->
        %{efforts | brake_torque_nm: efforts.brake_torque_nm + abs(torque)}

      {:steering_rad, angle}, efforts ->
        %{efforts | steering_rad: angle * 1.0}

      {:driveline_inertia_kg_m2, inertia}, efforts ->
        %{efforts | driveline_inertia_kg_m2: efforts.driveline_inertia_kg_m2 + inertia}
    end)
  end
end
