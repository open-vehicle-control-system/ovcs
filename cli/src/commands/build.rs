use anyhow::Result;
use std::path::PathBuf;
use std::time::Instant;

use crate::build_runner::{self, BuildLane, BuildStep};
use crate::firmware::{self, roles_for};
use crate::resolve_args::{resolve_vehicle_pair, resolve_vehicle_role};
use crate::shell;
use crate::ui;

pub fn run(all: bool, vehicle: Option<String>, role: Option<String>) -> Result<()> {
    if all {
        return run_all(vehicle, role);
    }
    // A single build streams its raw log live.
    let args = resolve_vehicle_role(vehicle, role)?;
    let role_firmware = firmware::resolve(&args.vehicle, &args.role)?;
    let cwd = args.repo_root.join(&role_firmware.firmware_dir);
    shell::run(
        &["./build.sh"],
        &shell::RunOpts {
            cwd: &cwd,
            env: &role_firmware.env,
        },
    )
}

/// Build every role the vehicle declares (vms, infotainment, each bridge)
/// concurrently. Each role is its own build (its own MIX_TARGET and
/// BRIDGE_FIRMWARE_ID) even when two share a firmware directory.
fn run_all(vehicle: Option<String>, role: Option<String>) -> Result<()> {
    let (root, vehicle) = resolve_vehicle_pair(vehicle, role)?;
    let roles = roles_for(&vehicle)?;

    println!();
    ui::step(&format!(
        "Building all {} role(s) for {}: {}",
        roles.len(),
        vehicle.dir,
        roles.join(", ")
    ));

    // Roles sharing a firmware dir build in one lane so they don't race on its deps/.
    let mut lanes: Vec<BuildLane> = Vec::new();
    for role in &roles {
        let role_firmware = firmware::resolve(&vehicle, role)?;
        let cwd: PathBuf = root.join(&role_firmware.firmware_dir);
        let step = BuildStep {
            panes: vec![role.clone()],
            env: role_firmware.env,
        };
        match lanes.iter_mut().find(|lane| lane.cwd == cwd) {
            Some(lane) => lane.steps.push(step),
            None => lanes.push(BuildLane {
                cwd,
                steps: vec![step],
            }),
        }
    }

    let start = Instant::now();
    build_runner::run_parallel(lanes)?;

    println!();
    ui::sub_ok(&format!(
        "built all {} role(s) for {} in {}",
        roles.len(),
        vehicle.dir,
        build_runner::fmt_elapsed(start.elapsed())
    ));
    Ok(())
}
