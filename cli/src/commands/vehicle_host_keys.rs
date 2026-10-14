use anyhow::{bail, Context, Result};
use owo_colors::OwoColorize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::firmware::{bridge_id, roles_for};
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_fail, sub_ok};
use crate::vehicles::Vehicle;

/// The host-key algorithms generated per role. RSA stays for older
/// clients; ed25519 is the modern default.
const KEY_KINDS: [&str; 2] = ["rsa", "ed25519"];

/// Generate persistent SSH host keys for every firmware role of a
/// vehicle. Keys land under `vehicles/<dir>/priv/host_keys/<role>/` and
/// are gitignored so each developer keeps their own; the firmware reads
/// them from the vehicle package's priv at runtime, so the device's SSH
/// identity stays stable across burns.
///
/// Idempotent — existing keys are left alone unless `--force` is set.
pub fn generate(arg: Option<String>, force: bool) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let roles = roles_for(&vehicle)?;
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
        sub(&format!(
            "{}  {}",
            role,
            relative_to_vehicle(&dir, &vehicle).dimmed()
        ));
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
    let roles = roles_for(&vehicle)?;
    if roles.is_empty() {
        step(&format!("{} declares no firmware roles.", vehicle.module));
        return Ok(());
    }

    step(&format!("Verifying host keys for {}:", vehicle.module));
    let mut complete = 0;
    let mut incomplete = 0;
    for role in &roles {
        let missing = missing_host_keys(&vehicle, role);
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
            "{} role(s) missing host keys — run `./ovcs host-keys generate {}`",
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
            "no host keys for {} — run `./ovcs host-keys generate {}` first",
            vehicle.dir,
            vehicle.dir
        );
    }

    let archive_path =
        absolute_path(&out.unwrap_or_else(|| format!("{}-host-keys.tar.gz", vehicle.dir)));
    // `-C <priv>` so the archive holds `host_keys/...` paths, which import
    // extracts straight back into another checkout's `priv/`.
    let priv_dir = vehicle.path.join("priv");
    // The archive holds private keys: create it readable by the user only.
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&archive_path)
            .with_context(|| format!("creating {}", archive_path.display()))?;
        std::fs::set_permissions(&archive_path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("restricting {}", archive_path.display()))?;
    }
    run_tar(
        &[
            "-czf".as_ref(),
            archive_path.as_os_str(),
            "-C".as_ref(),
            priv_dir.as_os_str(),
            "host_keys".as_ref(),
        ],
        "create archive",
    )?;

    step(&format!("Exported {} host keys", vehicle.module));
    sub_ok(&archive_path.display().to_string());
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
    let from = absolute_path(&from);
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
            "--no-same-owner".as_ref(),
            "-C".as_ref(),
            priv_dir.as_os_str(),
            "host_keys".as_ref(),
        ],
        "extract archive",
    )?;

    step(&format!("Imported host keys for {}", vehicle.module));
    sub_ok(&relative_to_vehicle(&base, &vehicle));
    println!(
        "{}",
        "Verify with `./ovcs host-keys verify`, then burn.".dimmed()
    );
    Ok(())
}

fn host_keys_dir(vehicle: &Vehicle) -> PathBuf {
    vehicle.path.join("priv").join("host_keys")
}

/// Directory holding `role`'s host keys (`role` as `roles_for`
/// names it: `vms`, `infotainment` or `bridge-<id>`).
pub(crate) fn role_dir(vehicle: &Vehicle, role: &str) -> PathBuf {
    let base = host_keys_dir(vehicle);
    // bridges/firmware's config/runtime.exs reads a bridge's keys from
    // `bridges/<id>`, with the bare id.
    match bridge_id(role) {
        Some(id) => base.join("bridges").join(id),
        None => base.join(role),
    }
}

/// The key files `role` lacks: each algorithm's private and public key.
pub(crate) fn missing_host_keys(vehicle: &Vehicle, role: &str) -> Vec<String> {
    let dir = role_dir(vehicle, role);
    KEY_KINDS
        .iter()
        .flat_map(|kind| {
            let private_key = format!("ssh_host_{}_key", kind);
            let public_key = format!("{}.pub", private_key);
            [private_key, public_key]
        })
        .filter(|name| !dir.join(name).exists())
        .collect()
}

/// True if at least one `ssh_host_*_key` lives anywhere under `base`.
fn has_keys(base: &Path) -> bool {
    let pattern = base.join("**").join("ssh_host_*_key");
    match pattern.to_str() {
        Some(pattern) => glob::glob(pattern)
            .map(|paths| paths.flatten().next().is_some())
            .unwrap_or(false),
        None => false,
    }
}

/// Path relative to the vehicle package, for tidy display.
fn relative_to_vehicle(path: &Path, vehicle: &Vehicle) -> String {
    path.strip_prefix(&vehicle.path)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn absolute_path(path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(&path))
            .unwrap_or(path)
    }
}

fn run_tar(args: &[&std::ffi::OsStr], what: &str) -> Result<()> {
    let output = Command::new("tar")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to spawn tar ({})", what))?;
    if !output.status.success() {
        sub_fail(&format!(
            "tar ({}) failed: {}",
            what,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
        bail!("tar exited {}", output.status);
    }
    Ok(())
}

fn ssh_keygen(kind: &str, key_path: &Path, comment: &str) -> Result<()> {
    let mut command = Command::new("ssh-keygen");
    command.args(["-t", kind]);
    if kind == "rsa" {
        command.args(["-b", "4096"]);
    }
    command
        .args(["-N", ""])
        .args(["-C", comment])
        .arg("-f")
        .arg(key_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    let output = command
        .output()
        .with_context(|| format!("failed to spawn ssh-keygen ({})", kind))?;
    if !output.status.success() {
        sub_fail(&format!(
            "ssh-keygen ({}) failed: {}",
            kind,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
        bail!("ssh-keygen exited {}", output.status);
    }
    Ok(())
}
