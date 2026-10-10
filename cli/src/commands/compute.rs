//! The compute node's balena release for a vehicle: `compose/compute/`
//! plus the vehicle's Nav2 parameters, staged into one source root since
//! balena needs every build context inside the pushed directory.

use anyhow::{bail, Context, Result};
use std::fs;
use std::path::Path;
use std::process::Command;

use crate::repo_root::repo_root;
use crate::resolve_args::resolve_vehicle;
use crate::ui;
use crate::vehicles::Vehicle;

/// Keyfiles hold PSKs and are installed on the host by hand, never pushed.
const NOT_STAGED: &[&str] = &["host"];

pub fn stage(vehicle: Option<String>, out: String) -> Result<()> {
    let vehicle = resolve_vehicle(vehicle)?;
    let out = Path::new(&out);
    if out.exists() && fs::read_dir(out)?.next().is_some() {
        bail!("{} is not empty", out.display());
    }
    stage_into(&vehicle, out)?;
    ui::sub_ok(&format!("staged {} into {}", vehicle.dir, out.display()));
    Ok(())
}

pub fn push(vehicle: String, target: String, balena_args: Vec<String>) -> Result<()> {
    let vehicle = resolve_vehicle(Some(vehicle))?;
    let out = std::env::temp_dir().join(format!(
        "ovcs-compute-{}-{}",
        vehicle.dir,
        std::process::id()
    ));
    stage_into(&vehicle, &out)?;

    ui::step(&format!(
        "balena push {} (source {})",
        target,
        out.display()
    ));
    let status = Command::new("balena")
        .arg("push")
        .arg(&target)
        .arg("--source")
        .arg(&out)
        .args(&balena_args)
        .status()
        .context("failed to spawn balena (run `mise install`)");
    fs::remove_dir_all(&out)?;
    let status = status?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

fn stage_into(vehicle: &Vehicle, out: &Path) -> Result<()> {
    let root = repo_root()?;
    let nav2 = vehicle.path.join("nav2");
    if !nav2.join("nav2.yaml").is_file() {
        bail!(
            "{} has no nav2/nav2.yaml: the compute node runs Nav2 with the vehicle's parameters",
            vehicle.dir
        );
    }

    ui::step(&format!("Staging the compute node for {}", vehicle.dir));
    fs::create_dir_all(out)?;
    for entry in fs::read_dir(root.join("compose/compute"))? {
        let entry = entry?;
        if NOT_STAGED.iter().any(|name| entry.file_name() == *name) {
            continue;
        }
        copy_tree(&entry.path(), &out.join(entry.file_name()))?;
    }
    copy_tree(&nav2, &out.join("vehicle/nav2"))?;
    ui::sub(&format!(
        "Nav2 parameters from vehicles/{}/nav2",
        vehicle.dir
    ));
    Ok(())
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        }
    } else {
        fs::copy(from, to).with_context(|| format!("copying {}", from.display()))?;
    }
    Ok(())
}
