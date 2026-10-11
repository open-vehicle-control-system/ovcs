use anyhow::{bail, Result};
use owo_colors::OwoColorize;
use std::process::{Command, Stdio};

use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_fail, sub_ok, sub_warn};
use crate::vehicles::{self, Vehicle};

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
            let output = String::from_utf8_lossy(&out.stdout);
            output.contains(",UP,") || output.contains("<UP,")
        }
        _ => false,
    }
}

/// Classified state of one host CAN interface — exists? up? Used by
/// both `setup` (to decide what to create/bring up) and `status` (to
/// paint the ✓ / ⚠ / ✗ tree). One place to ask the kernel, two
/// places to render it.
struct InterfaceProbe {
    name: String,
    exists: bool,
    up: bool,
}

fn probe_interfaces(interfaces: &[String]) -> Vec<InterfaceProbe> {
    interfaces
        .iter()
        .map(|name| {
            let exists = iface_exists(name);
            let up = exists && iface_up(name);
            InterfaceProbe {
                name: name.clone(),
                exists,
                up,
            }
        })
        .collect()
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
    if let Some(invalid) = interfaces.iter().find(|name| !is_interface_name(name)) {
        bail!(
            "{} declares the host CAN interface {:?}, which is not a valid interface name",
            vehicle.module,
            invalid
        );
    }
    if interfaces.is_empty() {
        step(&format!(
            "{} declares no host CAN interfaces — nothing to do.",
            vehicle.module
        ));
        return Ok(());
    }

    let probes = probe_interfaces(&interfaces);
    let mut actions: Vec<String> = Vec::new();
    if !vcan_loaded() {
        actions.push("load vcan module".to_string());
    }
    for probe in &probes {
        if !probe.exists {
            actions.push(format!("create {}", probe.name));
        } else if !probe.up {
            actions.push(format!("bring up {}", probe.name));
        }
    }

    if actions.is_empty() {
        step(&format!(
            "All virtual CAN interfaces for {} are already up — nothing to do.",
            vehicle.module
        ));
        return Ok(());
    }

    step(&format!("{} requires:", vehicle.module));
    for i in &interfaces {
        sub(i);
    }
    println!();
    step("Will run as root:");
    for a in &actions {
        sub(a);
    }
    println!();

    // The interface names arrive as the script's arguments, never as its text.
    let script = r#"
set -e
if ! lsmod | awk '{print $1}' | grep -qx vcan; then
  modprobe vcan
fi
for iface in "$@"; do
  if ! ip link show "$iface" >/dev/null 2>&1; then
    ip link add dev "$iface" type vcan
  fi
  ip link set up "$iface"
done
"#;

    step("Running sudo…");
    let mut cmd = Command::new("sudo");
    if sudo_cached() {
        cmd.arg("-n");
    }
    let status = cmd
        .args(["bash", "-c", script, "bash"])
        .args(&interfaces)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;
    if !status.success() {
        sub_fail("sudo failed");
        std::process::exit(1);
    }

    println!();
    step(&format!(
        "Virtual CAN interfaces ready for {}:",
        vehicle.module
    ));
    for iface in &interfaces {
        let state = iface_state_label(iface);
        sub_ok(&format!("{}  {}", iface, state.dimmed()));
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
        step(&format!(
            "{} declares no host CAN interfaces.",
            vehicle.module
        ));
        return Ok(());
    }
    step(&format!("{} host CAN interfaces:", vehicle.module));
    let probes = probe_interfaces(&interfaces);
    let mut missing = 0;
    for probe in &probes {
        if !probe.exists {
            sub_fail(&format!("{}  {}", probe.name, "not created".dimmed()));
            missing += 1;
        } else if !probe.up {
            sub_warn(&format!("{}  {}", probe.name, "down".dimmed()));
            missing += 1;
        } else {
            sub_ok(&format!("{}  {}", probe.name, "up".dimmed()));
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

/// A Linux interface name: at most 15 bytes, of the characters `ip link`
/// accepts without quoting.
fn is_interface_name(name: &str) -> bool {
    (1..=15).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

#[cfg(test)]
mod tests {
    use super::is_interface_name;

    #[test]
    fn interface_names_are_validated() {
        assert!(is_interface_name("vcan0"));
        assert!(is_interface_name("can_misc.1"));
        assert!(!is_interface_name(""));
        assert!(!is_interface_name("vcan0; reboot"));
        assert!(!is_interface_name("$(id)"));
        assert!(!is_interface_name("a-very-long-name0"));
    }
}
