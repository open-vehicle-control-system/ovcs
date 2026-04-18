use anyhow::{Result, bail};
use std::collections::HashMap;

use crate::vehicles::{self, Vehicle};

pub fn static_applications() -> &'static [&'static str] {
    &["vms", "infotainment"]
}

pub fn applications_for(vehicle: &Vehicle) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for app in static_applications() {
        if vehicles::nerves_target(vehicle, app)?.is_some() {
            out.push(app.to_string());
        }
    }
    let bridges = vehicles::bridge_firmwares(vehicle)?;
    out.extend(bridges.into_keys());
    Ok(out)
}

pub struct FirmwareResolution {
    pub firmware_dir: String,
    pub env: HashMap<String, String>,
}

pub fn resolve(vehicle: &Vehicle, application: &str) -> Result<FirmwareResolution> {
    let static_dir = match application {
        "vms" => Some("vms/firmware"),
        "infotainment" => Some("infotainment/firmware"),
        _ => None,
    };

    if let Some(dir) = static_dir {
        let mut env = HashMap::new();
        env.insert("VEHICLE".to_string(), vehicle.module.clone());
        if let Some(target) = vehicles::nerves_target(vehicle, application)? {
            env.insert("MIX_TARGET".to_string(), target);
        }
        return Ok(FirmwareResolution {
            firmware_dir: dir.to_string(),
            env,
        });
    }

    let bridges = vehicles::bridge_firmwares(vehicle)?;
    let Some(entry) = bridges.get(application) else {
        let valid: Vec<String> = static_applications()
            .iter()
            .map(|s| s.to_string())
            .chain(bridges.keys().cloned())
            .collect();
        bail!(
            "Unknown application {:?} for vehicle {}.\nExpected one of: {}",
            application,
            vehicle.dir,
            valid.join(", ")
        );
    };
    let mut env = HashMap::new();
    env.insert("VEHICLE".to_string(), vehicle.module.clone());
    env.insert("BRIDGE_FIRMWARE_ID".to_string(), application.to_string());
    env.insert("MIX_TARGET".to_string(), entry.target.clone());
    Ok(FirmwareResolution {
        firmware_dir: "bridges/firmware".to_string(),
        env,
    })
}
