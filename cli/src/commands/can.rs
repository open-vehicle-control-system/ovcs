use anyhow::{bail, Result};
use owo_colors::OwoColorize;
use std::process::{Command, Stdio};

use crate::prompt::choose;
use crate::repo_root::repo_root;
use crate::vehicles::{self, Vehicle};

fn resolve_vehicle(arg: Option<String>) -> Result<Vehicle> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    let names: Vec<String> = list.iter().map(|v| v.dir.clone()).collect();
    let vehicle_dir = match arg {
        Some(v) => v,
        None => choose("vehicle", &names)?,
    };
    match list.into_iter().find(|v| v.dir == vehicle_dir) {
        Some(v) => Ok(v),
        None => bail!("Unknown vehicle {}", vehicle_dir),
    }
}

fn iface_exists(iface: &str) -> bool {
    Command::new("ip")
        .args(["link", "show", iface])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// vcan devices always report `state UNKNOWN` (no carrier), so trust the
// IFF_UP flag in the flags column (`<NOARP,UP,LOWER_UP>`) instead.
fn iface_up(iface: &str) -> bool {
    match Command::new("ip").args(["link", "show", iface]).output() {
        Ok(out) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout);
            s.contains(",UP,") || s.contains("<UP,")
        }
        _ => false,
    }
}

fn vcan_loaded() -> bool {
    Command::new("sh")
        .args(["-c", "lsmod | awk '{print $1}' | grep -qx vcan"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn sudo_cached() -> bool {
    Command::new("sudo")
        .args(["-n", "true"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn iface_state_label(iface: &str) -> String {
    match Command::new("ip")
        .args(["-br", "link", "show", iface])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" "),
        _ => "?".to_string(),
    }
}

pub fn setup(arg: Option<String>) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    ensure_host_can(&vehicle)
}

/// Bring up every host vcan interface the vehicle needs. Idempotent —
/// interfaces already up are skipped. Used by both `can setup` and `run`.
pub fn ensure_host_can(vehicle: &Vehicle) -> Result<()> {
    let interfaces = vehicles::host_can_interfaces(vehicle)?;
    if interfaces.is_empty() {
        println!(
            "{}",
            format!(
                "No host CAN interfaces declared by {}.default_can_mapping(:host).",
                vehicle.module
            )
            .yellow()
        );
        return Ok(());
    }

    let mut actions: Vec<String> = Vec::new();
    if !vcan_loaded() {
        actions.push("load vcan module".to_string());
    }
    for iface in &interfaces {
        if !iface_exists(iface) {
            actions.push(format!("create {}", iface));
        } else if !iface_up(iface) {
            actions.push(format!("bring up {}", iface));
        }
    }

    if actions.is_empty() {
        println!(
            "{}",
            format!(
                "All virtual CAN interfaces for {} are already up — nothing to do.",
                vehicle.module
            )
            .green()
        );
        return Ok(());
    }

    println!("{}", format!("{} requires:", vehicle.module).bold());
    for i in &interfaces {
        println!("  - {}", i);
    }
    println!();
    println!("{}", "Will run as root:".bold());
    for a in &actions {
        println!("  - {}", a);
    }
    println!();

    let script = format!(
        r##"
set -e
if ! lsmod | awk '{{print $1}}' | grep -qx vcan; then
  modprobe vcan
fi
for iface in {ifaces}; do
  if ! ip link show "$iface" >/dev/null 2>&1; then
    ip link add dev "$iface" type vcan
  fi
  ip link set up "$iface"
done
"##,
        ifaces = interfaces.join(" ")
    );

    println!("{}", "→ sudo …".cyan());
    let mut cmd = Command::new("sudo");
    if sudo_cached() {
        cmd.arg("-n");
    }
    let status = cmd
        .args(["bash", "-c", &script])
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;
    if !status.success() {
        eprintln!("{}", "sudo failed".red());
        std::process::exit(1);
    }

    println!();
    println!(
        "{}",
        format!("Virtual CAN interfaces ready for {}:", vehicle.module).bold()
    );
    for iface in &interfaces {
        let state = iface_state_label(iface);
        println!("  {} {}  {}", "✓".green(), iface, state.dimmed());
    }
    println!();
    if let Some(first) = interfaces.first() {
        println!("{}", format!("Listen: candump -tz {}", first).dimmed());
        println!(
            "{}",
            format!("Send:   cansend {} 123#00FFAA5501020304", first).dimmed()
        );
    }
    Ok(())
}

pub fn status(arg: Option<String>) -> Result<()> {
    let vehicle = resolve_vehicle(arg)?;
    let interfaces = vehicles::host_can_interfaces(&vehicle)?;
    if interfaces.is_empty() {
        println!(
            "{}",
            format!("No host CAN interfaces declared by {}.", vehicle.module).yellow()
        );
        return Ok(());
    }
    println!(
        "{}",
        format!("{} host CAN interfaces:", vehicle.module).bold()
    );
    let mut missing = 0;
    for iface in &interfaces {
        if !iface_exists(iface) {
            println!("  {} {}  {}", "✗".red(), iface, "not created".dimmed());
            missing += 1;
        } else if !iface_up(iface) {
            println!("  {} {}  {}", "⚠".yellow(), iface, "down".dimmed());
            missing += 1;
        } else {
            println!("  {} {}  {}", "✓".green(), iface, "up".dimmed());
        }
    }
    println!();
    if missing == 0 {
        println!("{}", "All interfaces up.".green());
    } else {
        println!(
            "{}",
            format!("{} interface(s) missing or down.", missing).yellow()
        );
        println!(
            "{}",
            format!("Run: ovcs can setup {}", vehicle.dir).dimmed()
        );
        std::process::exit(1);
    }
    Ok(())
}
