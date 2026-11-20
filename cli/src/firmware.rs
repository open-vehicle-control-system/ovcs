use anyhow::{bail, Result};
use std::collections::HashMap;

use crate::vehicles::{self, Vehicle};

pub fn static_roles() -> &'static [&'static str] {
    &["vms", "infotainment", "vision"]
}

pub fn roles_for(vehicle: &Vehicle) -> Result<Vec<String>> {
    let mut roles = Vec::new();
    for role in static_roles() {
        if vehicles::nerves_target(vehicle, role)?.is_some() {
            roles.push(role.to_string());
        }
    }
    let bridges = vehicles::bridge_firmwares(vehicle)?;
    roles.extend(bridges.into_keys().map(|id| format!("bridge-{}", id)));
    Ok(roles)
}

/// If `role` is a `bridge-<id>` role, return the bare bridge id.
pub fn bridge_id(role: &str) -> Option<&str> {
    role.strip_prefix("bridge-")
}

pub struct FirmwareResolution {
    pub firmware_dir: String,
    pub env: HashMap<String, String>,
}

/// Firmware project of a fixed role; `None` for bridge roles.
fn static_firmware_dir(role: &str) -> Option<&'static str> {
    match role {
        "vms" => Some("vms/firmware"),
        "infotainment" => Some("infotainment/firmware"),
        "vision" => Some("vision/firmware"),
        _ => None,
    }
}

/// What every command run for `vehicle` is told: its module and where its package is,
/// absolute, since those commands run from their own folders.
pub fn firmware_env(vehicle: &Vehicle) -> HashMap<String, String> {
    let path = std::path::absolute(&vehicle.path).unwrap_or_else(|_| vehicle.path.clone());
    HashMap::from([
        ("VEHICLE".to_string(), vehicle.module.clone()),
        (
            "OVCS_VEHICLE_PATH".to_string(),
            path.to_string_lossy().into_owned(),
        ),
    ])
}

pub fn resolve(vehicle: &Vehicle, role: &str) -> Result<FirmwareResolution> {
    if let Some(dir) = static_firmware_dir(role) {
        let mut env = firmware_env(vehicle);
        if let Some(target) = vehicles::nerves_target(vehicle, role)? {
            env.insert("MIX_TARGET".to_string(), target);
        }
        return Ok(FirmwareResolution {
            firmware_dir: dir.to_string(),
            env,
        });
    }

    let bridges = vehicles::bridge_firmwares(vehicle)?;
    let id = bridge_id(role).unwrap_or("");
    let Some(entry) = bridges.get(id) else {
        let valid: Vec<String> = static_roles()
            .iter()
            .map(|s| s.to_string())
            .chain(bridges.keys().map(|k| format!("bridge-{}", k)))
            .collect();
        bail!(
            "Unknown role {:?} for vehicle {}.\nExpected one of: {}",
            role,
            vehicle.dir,
            valid.join(", ")
        );
    };
    let mut env = firmware_env(vehicle);
    env.insert("BRIDGE_FIRMWARE_ID".to_string(), id.to_string());
    env.insert("MIX_TARGET".to_string(), entry.target.clone());
    Ok(FirmwareResolution {
        firmware_dir: "bridges/firmware".to_string(),
        env,
    })
}

#[cfg(test)]
mod tests {
    use super::{firmware_env, static_firmware_dir, static_roles};
    use crate::vehicles::Vehicle;
    use std::path::PathBuf;

    #[test]
    fn resolve_vision_role_points_at_vision_firmware() {
        assert_eq!(static_firmware_dir("vision"), Some("vision/firmware"));
        assert_eq!(static_firmware_dir("vms"), Some("vms/firmware"));
        assert_eq!(
            static_firmware_dir("infotainment"),
            Some("infotainment/firmware")
        );
        assert_eq!(static_firmware_dir("bridge-ros"), None);
    }

    #[test]
    fn vision_is_a_static_role() {
        assert!(static_roles().contains(&"vision"));
    }

    #[test]
    fn a_firmware_command_is_told_the_vehicle_and_where_it_is() {
        let vehicle = Vehicle {
            dir: "roomba".to_string(),
            module: "Roomba".to_string(),
            path: PathBuf::from("/src/ovcs-roomba"),
        };
        let env = firmware_env(&vehicle);
        assert_eq!(env["VEHICLE"], "Roomba");
        assert_eq!(env["OVCS_VEHICLE_PATH"], "/src/ovcs-roomba");
    }

    #[test]
    fn a_relative_vehicle_path_reaches_firmware_commands_absolute() {
        let vehicle = Vehicle {
            dir: "roomba".to_string(),
            module: "Roomba".to_string(),
            path: PathBuf::from("vehicles/roomba"),
        };
        let expected = std::env::current_dir().unwrap().join("vehicles/roomba");
        assert_eq!(
            firmware_env(&vehicle)["OVCS_VEHICLE_PATH"],
            expected.to_string_lossy()
        );
    }
}
