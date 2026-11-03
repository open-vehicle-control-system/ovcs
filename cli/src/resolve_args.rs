use anyhow::{anyhow, bail, Result};
use owo_colors::OwoColorize;

use crate::firmware::roles_for;
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
            .find(|vehicle| vehicle.dir == dir)
            .ok_or_else(|| anyhow!("Unknown vehicle {}", dir)),
        None => choose_vehicle(&list),
    }
}

pub struct ResolvedArgs {
    pub repo_root: std::path::PathBuf,
    pub vehicle: Vehicle,
    pub role: String,
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
    let values: Vec<String> = [vehicle_arg, role_arg].into_iter().flatten().collect();
    let vehicle = named_or_chosen_vehicle(&values, &all)?;
    Ok((root, vehicle))
}

/// The vehicle the first of `values` naming one designates, else the
/// interactive picker's choice.
fn named_or_chosen_vehicle(values: &[String], all: &[Vehicle]) -> Result<Vehicle> {
    let dirs: Vec<String> = all.iter().map(|vehicle| vehicle.dir.clone()).collect();
    match vehicle_among(values, &dirs) {
        Some(dir) => match all.iter().find(|vehicle| vehicle.dir == dir) {
            Some(vehicle) => Ok(vehicle.clone()),
            None => bail!("Unknown vehicle {}", dir),
        },
        None => choose_vehicle(all),
    }
}

/// The first of `values` that is one of `vehicle_dirs`.
fn vehicle_among<'a>(values: &'a [String], vehicle_dirs: &[String]) -> Option<&'a str> {
    values
        .iter()
        .find(|value| vehicle_dirs.contains(value))
        .map(String::as_str)
}

/// What the positional values say about the role, once `vehicle_dir`
/// has been taken out of them.
#[derive(Debug, PartialEq)]
enum RoleChoice {
    Role(String),
    /// No value left: ask interactively.
    Ask,
    /// A leftover value that is not one of the vehicle's roles.
    Unknown(String),
}

fn role_among(values: &[String], vehicle_dir: &str, valid_roles: &[String]) -> RoleChoice {
    let remaining: Vec<&String> = values
        .iter()
        .filter(|value| *value != vehicle_dir)
        .collect();
    match remaining.iter().find(|value| valid_roles.contains(value)) {
        Some(role) => RoleChoice::Role(role.to_string()),
        None => match remaining.first() {
            None => RoleChoice::Ask,
            Some(unknown) => RoleChoice::Unknown(unknown.to_string()),
        },
    }
}

/// Resolve a (vehicle, role) pair from two order-independent positional
/// args. Either or both may be omitted — missing values fall back to the
/// interactive Ratatui picker.
pub fn resolve_vehicle_role(
    vehicle_arg: Option<String>,
    role_arg: Option<String>,
) -> Result<ResolvedArgs> {
    let root = repo_root()?;
    let all = vehicles::list(&root)?;
    let values: Vec<String> = [vehicle_arg, role_arg].into_iter().flatten().collect();
    let vehicle = named_or_chosen_vehicle(&values, &all)?;
    let vehicle_dir = vehicle.dir.clone();

    let valid_roles = roles_for(&vehicle)?;
    let role = match role_among(&values, &vehicle_dir, &valid_roles) {
        RoleChoice::Role(role) => role,
        RoleChoice::Ask => choose("role", &valid_roles)?,
        RoleChoice::Unknown(unknown_role) => {
            eprintln!(
                "{}",
                format!(
                    "Unknown role {:?} for vehicle {}.\nValid: {}",
                    unknown_role,
                    vehicle_dir,
                    valid_roles.join(", ")
                )
                .red()
            );
            std::process::exit(1);
        }
    };

    Ok(ResolvedArgs {
        repo_root: root,
        vehicle,
        role,
    })
}

#[cfg(test)]
mod tests {
    use super::{role_among, vehicle_among, RoleChoice};

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn vehicle_dirs() -> Vec<String> {
        strings(&["obd2", "ovcs1", "ovcs_mini"])
    }

    fn ovcs1_roles() -> Vec<String> {
        strings(&["vms", "infotainment", "vision", "bridge-ros"])
    }

    #[test]
    fn vehicle_and_role_may_come_in_either_order() {
        for values in [strings(&["ovcs1", "vms"]), strings(&["vms", "ovcs1"])] {
            assert_eq!(vehicle_among(&values, &vehicle_dirs()), Some("ovcs1"));
            assert_eq!(
                role_among(&values, "ovcs1", &ovcs1_roles()),
                RoleChoice::Role("vms".to_string())
            );
        }
    }

    #[test]
    fn resolve_args_accepts_vision_role() {
        for values in [strings(&["ovcs1", "vision"]), strings(&["vision", "ovcs1"])] {
            assert_eq!(vehicle_among(&values, &vehicle_dirs()), Some("ovcs1"));
            assert_eq!(
                role_among(&values, "ovcs1", &ovcs1_roles()),
                RoleChoice::Role("vision".to_string())
            );
        }
    }

    #[test]
    fn a_missing_role_is_asked_for() {
        let values = strings(&["ovcs1"]);
        assert_eq!(
            role_among(&values, "ovcs1", &ovcs1_roles()),
            RoleChoice::Ask
        );
    }

    #[test]
    fn a_role_the_vehicle_lacks_is_unknown() {
        let values = strings(&["bridge-radio_control", "ovcs1"]);
        assert_eq!(vehicle_among(&values, &vehicle_dirs()), Some("ovcs1"));
        assert_eq!(
            role_among(&values, "ovcs1", &ovcs1_roles()),
            RoleChoice::Unknown("bridge-radio_control".to_string())
        );
    }

    #[test]
    fn a_value_naming_neither_leaves_the_vehicle_to_the_picker_and_is_an_unknown_role() {
        let values = strings(&["roadster"]);
        assert_eq!(vehicle_among(&values, &vehicle_dirs()), None);
        assert_eq!(
            role_among(&values, "ovcs1", &ovcs1_roles()),
            RoleChoice::Unknown("roadster".to_string())
        );
    }

    #[test]
    fn of_two_vehicles_the_first_wins_and_the_second_is_an_unknown_role() {
        let values = strings(&["ovcs_mini", "ovcs1"]);
        assert_eq!(vehicle_among(&values, &vehicle_dirs()), Some("ovcs_mini"));
        assert_eq!(
            role_among(&values, "ovcs_mini", &ovcs1_roles()),
            RoleChoice::Unknown("ovcs1".to_string())
        );
    }
}
