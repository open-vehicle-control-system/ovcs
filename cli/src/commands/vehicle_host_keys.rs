use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::firmware::applications_for;
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_fail, sub_ok};
use crate::vehicles::Vehicle;

/// Generate persistent SSH host keys for every firmware role of a
/// vehicle. Keys land under `vehicles/<dir>/priv/host_keys/<role>/` and
/// are gitignored so each developer keeps their own; the firmware boot
/// path picks them up from the vehicle's app priv at runtime, so the
/// device's SSH identity stays stable across burns.
///
/// Idempotent — existing keys are left alone unless `--force` is set.
pub fn run(arg: Option<String>, force: bool) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let roles = applications_for(&vehicle)?;
    if roles.is_empty() {
        step(&format!("{} declares no firmware roles.", vehicle.module));
        return Ok(());
    }

    step(&format!("Host keys for {}:", vehicle.module));
    let mut created = 0;
    let mut kept = 0;
    for role in &roles {
        let dir = role_dir(&vehicle, role);
        std::fs::create_dir_all(&dir)
            .with_context(|| format!("creating {}", dir.display()))?;
        sub(&format!(
            "{}  {}",
            role,
            dir.strip_prefix(&vehicle.path)
                .unwrap_or(&dir)
                .display()
                .to_string()
                .dimmed()
        ));
        for kind in ["rsa", "ed25519"] {
            let key_path = dir.join(format!("ssh_host_{}_key", kind));
            if key_path.exists() && !force {
                sub_ok(&format!("ssh_host_{}_key (kept)", kind));
                kept += 1;
                continue;
            }
            if force && key_path.exists() {
                let _ = std::fs::remove_file(&key_path);
                let _ = std::fs::remove_file(key_path.with_extension("pub"));
            }
            let comment = format!("{}-{}", vehicle.dir, role.replace('/', "-"));
            ssh_keygen(kind, &key_path, &comment)?;
            sub_ok(&format!("ssh_host_{}_key (generated)", kind));
            created += 1;
        }
    }

    println!();
    step(&format!(
        "{} role(s); {} key(s) generated, {} kept",
        roles.len(),
        created,
        kept
    ));
    if created == 0 && !force {
        println!(
            "{}",
            "All keys already in place. Use --force to regenerate.".dimmed()
        );
    } else {
        println!(
            "{}",
            "Burn the firmware again — devices will use these keys.".dimmed()
        );
    }
    Ok(())
}

fn role_dir(vehicle: &Vehicle, role: &str) -> PathBuf {
    let base = vehicle.path.join("priv").join("host_keys");
    match role {
        "vms" | "infotainment" => base.join(role),
        bridge_id => base.join("bridges").join(bridge_id),
    }
}

fn ssh_keygen(kind: &str, key_path: &Path, comment: &str) -> Result<()> {
    let mut cmd = Command::new("ssh-keygen");
    cmd.args(["-t", kind]);
    if kind == "rsa" {
        cmd.args(["-b", "4096"]);
    }
    cmd.args(["-N", ""])
        .args(["-C", comment])
        .arg("-f")
        .arg(key_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    let out = cmd
        .output()
        .with_context(|| format!("failed to spawn ssh-keygen ({})", kind))?;
    if !out.status.success() {
        sub_fail(&format!(
            "ssh-keygen ({}) failed: {}",
            kind,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
        anyhow::bail!("ssh-keygen exited {}", out.status);
    }
    Ok(())
}
