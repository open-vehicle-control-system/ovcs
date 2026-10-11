use anyhow::{bail, Result};
use std::collections::HashMap;

use crate::vehicles::{self, Vehicle};

pub fn static_roles() -> &'static [&'static str] {
    &["vms", "infotainment"]
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

pub fn resolve(vehicle: &Vehicle, role: &str) -> Result<FirmwareResolution> {
    let static_dir = match role {
        "vms" => Some("vms/firmware"),
        "infotainment" => Some("infotainment/firmware"),
        _ => None,
    };

    if let Some(dir) = static_dir {
        let mut env = HashMap::new();
        env.insert("VEHICLE".to_string(), vehicle.module.clone());
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
    let mut env = HashMap::new();
    env.insert("VEHICLE".to_string(), vehicle.module.clone());
    env.insert("BRIDGE_FIRMWARE_ID".to_string(), id.to_string());
    env.insert("MIX_TARGET".to_string(), entry.target.clone());
    Ok(FirmwareResolution {
        firmware_dir: "bridges/firmware".to_string(),
        env,
    })
}
