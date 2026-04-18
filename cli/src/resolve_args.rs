use anyhow::{Result, bail};
use owo_colors::OwoColorize;

use crate::firmware::applications_for;
use crate::prompt::choose;
use crate::repo_root::repo_root;
use crate::vehicles::{self, Vehicle};

pub struct ResolvedArgs {
    pub repo_root: std::path::PathBuf,
    pub vehicle: Vehicle,
    pub application: String,
}

pub fn resolve_vehicle_app(
    first: Option<String>,
    second: Option<String>,
) -> Result<ResolvedArgs> {
    let root = repo_root()?;
    let all = vehicles::list(&root)?;
    let names: Vec<String> = all.iter().map(|v| v.dir.clone()).collect();

    let values: Vec<String> = [first, second].into_iter().flatten().collect();
    let vehicle_dir = match values.iter().find(|v| names.contains(v)).cloned() {
        Some(v) => v,
        None => choose("vehicle", &names)?,
    };

    let Some(vehicle) = all.into_iter().find(|v| v.dir == vehicle_dir) else {
        bail!("Unknown vehicle {}", vehicle_dir);
    };

    let valid_apps = applications_for(&vehicle)?;
    let remaining: Vec<String> = values.into_iter().filter(|v| v != &vehicle_dir).collect();
    let application = match remaining.iter().find(|v| valid_apps.contains(v)).cloned() {
        Some(a) => a,
        None => {
            if remaining.is_empty() {
                choose("application", &valid_apps)?
            } else {
                let bad = &remaining[0];
                eprintln!(
                    "{}",
                    format!(
                        "Unknown application {:?} for vehicle {}.\nValid: {}",
                        bad,
                        vehicle_dir,
                        valid_apps.join(", ")
                    )
                    .red()
                );
                std::process::exit(1);
            }
        }
    };

    Ok(ResolvedArgs {
        repo_root: root,
        vehicle,
        application,
    })
}
