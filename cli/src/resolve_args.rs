use anyhow::{anyhow, bail, Result};
use owo_colors::OwoColorize;

use crate::firmware::applications_for;
use crate::prompt::{choose, choose_vehicle};
use crate::repo_root::repo_root;
use crate::vehicles::{self, Vehicle};

/// Resolve a single `vehicle` argument: if `arg` matches a known
/// directory name use that vehicle, otherwise fall back to the
/// interactive picker. Shared by `run`, `attach`, `can setup`, and
/// `can status` — they all front the same "pick one vehicle" UX.
pub fn resolve_vehicle(arg: Option<String>) -> Result<Vehicle> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    match arg {
        Some(dir) => list
            .into_iter()
            .find(|v| v.dir == dir)
            .ok_or_else(|| anyhow!("Unknown vehicle {}", dir)),
        None => choose_vehicle(&list),
    }
}

pub struct ResolvedArgs {
    pub repo_root: std::path::PathBuf,
    pub vehicle: Vehicle,
    pub application: String,
}

/// Pick just the vehicle out of the two order-independent positional args,
/// ignoring whichever value isn't a known vehicle (e.g. a stray role).
/// Falls back to the interactive picker when neither names a vehicle.
/// Used by `build --all`, which builds every role and so needs no role arg.
pub fn resolve_vehicle_pair(
    vehicle_arg: Option<String>,
    role_arg: Option<String>,
) -> Result<(std::path::PathBuf, Vehicle)> {
    let root = repo_root()?;
    let all = vehicles::list(&root)?;
    let names: Vec<String> = all.iter().map(|v| v.dir.clone()).collect();
    let values: Vec<String> = [vehicle_arg, role_arg].into_iter().flatten().collect();
    let vehicle = match values.iter().find(|v| names.contains(v)).cloned() {
        Some(dir) => match all.iter().find(|v| v.dir == dir) {
            Some(v) => v.clone(),
            None => bail!("Unknown vehicle {}", dir),
        },
        None => choose_vehicle(&all)?,
    };
    Ok((root, vehicle))
}

/// Resolve a (vehicle, role) pair from two order-independent positional
/// args. Either or both may be omitted — missing values fall back to the
/// interactive Ratatui picker. The struct field is still called
/// `application` internally; user-facing strings call it the role.
pub fn resolve_vehicle_app(
    vehicle_arg: Option<String>,
    role_arg: Option<String>,
) -> Result<ResolvedArgs> {
    let root = repo_root()?;
    let all = vehicles::list(&root)?;
    let names: Vec<String> = all.iter().map(|v| v.dir.clone()).collect();

    let values: Vec<String> = [vehicle_arg, role_arg].into_iter().flatten().collect();
    let vehicle = match values.iter().find(|v| names.contains(v)).cloned() {
        Some(dir) => match all.iter().find(|v| v.dir == dir) {
            Some(v) => v.clone(),
            None => bail!("Unknown vehicle {}", dir),
        },
        None => choose_vehicle(&all)?,
    };
    let vehicle_dir = vehicle.dir.clone();

    let valid_roles = applications_for(&vehicle)?;
    let remaining: Vec<String> = values.into_iter().filter(|v| v != &vehicle_dir).collect();
    let application = match remaining.iter().find(|v| valid_roles.contains(v)).cloned() {
        Some(a) => a,
        None => {
            if remaining.is_empty() {
                choose("role", &valid_roles)?
            } else {
                let bad = &remaining[0];
                eprintln!(
                    "{}",
                    format!(
                        "Unknown role {:?} for vehicle {}.\nValid: {}",
                        bad,
                        vehicle_dir,
                        valid_roles.join(", ")
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
