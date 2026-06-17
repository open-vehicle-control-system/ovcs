use anyhow::{bail, Context, Result};
use owo_colors::OwoColorize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::firmware::{applications_for, bridge_id};
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_fail, sub_ok};
use crate::vehicles::Vehicle;

/// The two host-key algorithms we generate per role. RSA stays for older
/// clients; ed25519 is the modern default.
const KEY_KINDS: [&str; 2] = ["rsa", "ed25519"];

/// Generate persistent SSH host keys for every firmware role of a
/// vehicle. Keys land under `vehicles/<dir>/priv/host_keys/<role>/` and
/// are gitignored so each developer keeps their own; the firmware boot
/// path picks them up from the vehicle's app priv at runtime, so the
/// device's SSH identity stays stable across burns.
///
/// Idempotent — existing keys are left alone unless `--force` is set.
pub fn generate(arg: Option<String>, force: bool) -> Result<()> {
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
        std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        sub(&format!("{}  {}", role, rel(&dir, &vehicle).dimmed()));
        for kind in KEY_KINDS {
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

/// Check that every role has a complete set of host keys (both algorithms,
/// private + public). Reports per role and exits non-zero if any are
/// missing, so it's usable as a pre-burn / CI gate.
pub fn verify(arg: Option<String>) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let roles = applications_for(&vehicle)?;
    if roles.is_empty() {
        step(&format!("{} declares no firmware roles.", vehicle.module));
        return Ok(());
    }

    step(&format!("Verifying host keys for {}:", vehicle.module));
    let mut complete = 0;
    let mut incomplete = 0;
    for role in &roles {
        let dir = role_dir(&vehicle, role);
        let missing: Vec<String> = KEY_KINDS
            .iter()
            .flat_map(|kind| {
                let key = dir.join(format!("ssh_host_{}_key", kind));
                let pubkey = key.with_extension("pub");
                let mut gaps = Vec::new();
                if !key.exists() {
                    gaps.push(format!("ssh_host_{}_key", kind));
                }
                if !pubkey.exists() {
                    gaps.push(format!("ssh_host_{}_key.pub", kind));
                }
                gaps
            })
            .collect();

        if missing.is_empty() {
            sub_ok(&format!("{}  complete", role));
            complete += 1;
        } else {
            sub_fail(&format!("{}  missing: {}", role, missing.join(", ")));
            incomplete += 1;
        }
    }

    println!();
    step(&format!("{}/{} role(s) complete", complete, roles.len()));
    if incomplete > 0 {
        bail!(
            "{} role(s) missing host keys — run `ovcs host-keys generate {}`",
            incomplete,
            vehicle.dir
        );
    }
    Ok(())
}

/// Bundle a vehicle's whole `priv/host_keys/` tree into a gzip tar so
/// another developer can `import` it and share the same device SSH
/// identity. The archive contains PRIVATE keys — share it over a trusted
/// channel.
pub fn export(arg: Option<String>, out: Option<String>) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let base = host_keys_dir(&vehicle);
    if !has_keys(&base) {
        bail!(
            "no host keys for {} — run `ovcs host-keys generate {}` first",
            vehicle.dir,
            vehicle.dir
        );
    }

    let out = abs_path(&out.unwrap_or_else(|| format!("{}-host-keys.tar.gz", vehicle.dir)));
    // `-C <priv>` so the archive holds `host_keys/...` paths, which import
    // extracts straight back into another checkout's `priv/`.
    let priv_dir = vehicle.path.join("priv");
    run_tar(
        &[
            "-czf".as_ref(),
            out.as_os_str(),
            "-C".as_ref(),
            priv_dir.as_os_str(),
            "host_keys".as_ref(),
        ],
        "create archive",
    )?;

    step(&format!("Exported {} host keys", vehicle.module));
    sub_ok(&out.display().to_string());
    println!(
        "{}",
        "Contains private keys — share over a trusted channel.".dimmed()
    );
    Ok(())
}

/// Restore a vehicle's host keys from an `export` archive. Refuses to
/// clobber existing keys unless `--force`.
pub fn import(arg: Option<String>, from: String, force: bool) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let from = abs_path(&from);
    if !from.is_file() {
        bail!("archive not found: {}", from.display());
    }

    let base = host_keys_dir(&vehicle);
    if has_keys(&base) && !force {
        bail!(
            "{} already has host keys — pass --force to overwrite",
            vehicle.dir
        );
    }

    let priv_dir = vehicle.path.join("priv");
    std::fs::create_dir_all(&priv_dir)
        .with_context(|| format!("creating {}", priv_dir.display()))?;
    run_tar(
        &[
            "-xzf".as_ref(),
            from.as_os_str(),
            "-C".as_ref(),
            priv_dir.as_os_str(),
        ],
        "extract archive",
    )?;

    step(&format!("Imported host keys for {}", vehicle.module));
    sub_ok(&rel(&base, &vehicle));
    println!(
        "{}",
        "Verify with `ovcs host-keys verify`, then burn.".dimmed()
    );
    Ok(())
}

fn host_keys_dir(vehicle: &Vehicle) -> PathBuf {
    vehicle.path.join("priv").join("host_keys")
}

fn role_dir(vehicle: &Vehicle, role: &str) -> PathBuf {
    let base = host_keys_dir(vehicle);
    // Bridge roles arrive as `bridge-<id>` (from `applications_for`), but
    // the firmware reads keys at `bridges/<id>` — bridges/firmware's
    // config/runtime.exs calls
    // `ssh_system_dir(vehicle, "bridges/#{bridge_firmware_id}")` with the
    // bare id. Strip the prefix so the two paths agree.
    match bridge_id(role) {
        Some(id) => base.join("bridges").join(id),
        None => base.join(role),
    }
}

/// True if at least one `ssh_host_*_key` lives anywhere under `base`.
fn has_keys(base: &Path) -> bool {
    let pattern = base.join("**").join("ssh_host_*_key");
    match pattern.to_str() {
        Some(p) => glob::glob(p)
            .map(|paths| paths.flatten().next().is_some())
            .unwrap_or(false),
        None => false,
    }
}

/// Path relative to the vehicle package, for tidy display.
fn rel(path: &Path, vehicle: &Vehicle) -> String {
    path.strip_prefix(&vehicle.path)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn abs_path(p: &str) -> PathBuf {
    let path = PathBuf::from(p);
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(&path))
            .unwrap_or(path)
    }
}

fn run_tar(args: &[&std::ffi::OsStr], what: &str) -> Result<()> {
    let out = Command::new("tar")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to spawn tar ({})", what))?;
    if !out.status.success() {
        sub_fail(&format!(
            "tar ({}) failed: {}",
            what,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
        bail!("tar exited {}", out.status);
    }
    Ok(())
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
        bail!("ssh-keygen exited {}", out.status);
    }
    Ok(())
}
