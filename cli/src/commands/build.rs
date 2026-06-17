use anyhow::Result;
use std::path::PathBuf;
use std::time::Instant;

use crate::build_runner::{self, BuildLane, BuildStep};
use crate::firmware::{self, applications_for};
use crate::resolve_args::{resolve_vehicle_app, resolve_vehicle_pair};
use crate::shell;
use crate::ui;

pub fn run(all: bool, vehicle: Option<String>, role: Option<String>) -> Result<()> {
    if all {
        return run_all(vehicle, role);
    }
    // Single role: stream the build live with inherited stdio (the user
    // asked for one firmware, so the raw build log is what they want).
    let args = resolve_vehicle_app(vehicle, role)?;
    let res = firmware::resolve(&args.vehicle, &args.application)?;
    let cwd = args.repo_root.join(&res.firmware_dir);
    shell::run(
        &["./build.sh"],
        &shell::RunOpts {
            cwd: &cwd,
            env: &res.env,
        },
    )
}

/// Build every role the vehicle declares (vms, infotainment, each bridge)
/// concurrently. Each role is its own firmware build — different
/// MIX_TARGET (and BRIDGE_FIRMWARE_ID for bridges) — even when two share
/// a firmware directory, so we run one job per role rather than per dir.
fn run_all(vehicle: Option<String>, role: Option<String>) -> Result<()> {
    let (root, vehicle) = resolve_vehicle_pair(vehicle, role)?;
    let roles = applications_for(&vehicle)?;

    println!();
    ui::step(&format!(
        "Building all {} role(s) for {}: {}",
        roles.len(),
        vehicle.dir,
        roles.join(", ")
    ));

    // Group roles by firmware directory. Roles sharing a dir (the bridge
    // roles all live in bridges/firmware) become sequential steps in one
    // lane so they don't race on that project's deps/; distinct dirs are
    // separate lanes and build in parallel.
    let mut lanes: Vec<BuildLane> = Vec::new();
    for role in &roles {
        let res = firmware::resolve(&vehicle, role)?;
        let cwd: PathBuf = root.join(&res.firmware_dir);
        let step = BuildStep {
            panes: vec![role.clone()],
            env: res.env,
        };
        match lanes.iter_mut().find(|l| l.cwd == cwd) {
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
