use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::io::{BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;

use crate::ansi::{is_blank_after_ansi, strip_ansi};
use crate::build_runner::{self, BuildLane, BuildStep};
use crate::commands::can::ensure_host_can;
use crate::erlang_cookie;
use crate::firmware;
use crate::lines::lossy_lines;
use crate::repo_root::repo_root;
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_ok, sub_warn};
use crate::vehicles::{self, Vehicle};

/// How long a child has to stop after SIGTERM before it gets SIGKILL.
const STOP_GRACE: std::time::Duration = std::time::Duration::from_secs(10);

pub fn run(vehicle_arg: Option<String>, no_addons: bool) -> Result<()> {
    let vehicle = resolve_vehicle(vehicle_arg)?;
    let root = repo_root()?;

    ensure_host_can(&vehicle)?;

    let roles = enumerate_roles(&root, &vehicle)?;
    if roles.is_empty() {
        anyhow::bail!("no roles to spawn for vehicle {}", vehicle.dir);
    }

    println!();
    step(&format!(
        "Booting vehicle {} locally ({} BEAMs, OvcsBus.Cluster)",
        vehicle.dir,
        roles.len()
    ));
    let sname_width = roles
        .iter()
        .map(|role| vehicles::local_sname(&vehicle.dir, &role.label).len())
        .max()
        .unwrap_or(0);
    for role in &roles {
        let sname = vehicles::local_sname(&vehicle.dir, &role.label);
        sub(&format!(
            "{:<width$}  {}",
            sname,
            short_path(&role.cwd, &root),
            width = sname_width
        ));
    }
    sub("Attach with `./ovcs attach` in another terminal · Ctrl-C to stop.");
    println!();

    // The firmware's own build.sh, in host mode, keeps its prep steps in one place.
    ensure_built(&roles, &vehicle)?;

    // Asked only now: the firmware projects must be compiled to answer `dev_addons/0`.
    let addons = if no_addons {
        Vec::new()
    } else {
        ensure_addon_deps(discover_addons(&roles)?)
    };

    erlang_cookie::ensure()?;
    let mut processes: Vec<ChildProcess> = Vec::new();

    for role in &roles {
        let sname = vehicles::local_sname(&vehicle.dir, &role.label);
        let mut command = Command::new("elixir");
        command
            .args([
                "--sname",
                &sname,
                // The BEAM disables `IO.ANSI` on a piped stdout; keep Logger's colours.
                // No scheduler busy-wait, as in the firmware's vm.args: on a
                // many-core host the idle schedulers spin.
                "--erl",
                "-elixir ansi_enabled true +sbwt none +sbwtdcpu none +sbwtdio none",
                "-S",
                "mix",
                "run",
                "--no-halt",
            ])
            .current_dir(&role.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (name, value) in &role.env {
            command.env(name, value);
        }
        // An exported Nerves target would make these target-mode BEAMs.
        command.env("MIX_TARGET", "host");
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                stop(&mut processes);
                return Err(error)
                    .with_context(|| format!("failed to spawn elixir for role {}", role.label));
            }
        };

        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let label_out = role.label.clone();
        let label_err = role.label.clone();
        thread::spawn(move || prefix_stream(stdout, &label_out, std::io::stdout()));
        thread::spawn(move || prefix_stream(stderr, &label_err, std::io::stderr()));

        processes.push(ChildProcess {
            label: role.label.clone(),
            child,
            critical: true,
            exit: None,
        });
    }

    // Add-ons are not critical: a crashed dev server must not stop the vehicle.
    for addon in &addons {
        let mut command = Command::new(&addon.run[0]);
        command
            .args(&addon.run[1..])
            .current_dir(&addon.dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                sub_warn(&format!(
                    "{}: failed to start `{}` ({error}) — skipping",
                    addon.label,
                    addon.run.join(" ")
                ));
                continue;
            }
        };
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let label_out = addon.label.clone();
        let label_err = addon.label.clone();
        thread::spawn(move || prefix_stream(stdout, &label_out, std::io::stdout()));
        thread::spawn(move || prefix_stream(stderr, &label_err, std::io::stderr()));
        match &addon.note {
            Some(note) => sub_ok(&format!("{} — {}", addon.label, note)),
            None => sub_ok(&format!("{} · {}", addon.label, addon.run.join(" "))),
        }
        processes.push(ChildProcess {
            label: addon.label.clone(),
            child,
            critical: false,
            exit: None,
        });
    }
    if !addons.is_empty() {
        println!();
    }

    // Ctrl-C reaches the whole process group and ends this process too, so
    // returning from `supervise` means a BEAM exited on its own.
    match supervise(&mut processes) {
        Some((label, status)) => bail!("{} exited ({}); the vehicle was stopped", label, status),
        None => Ok(()),
    }
}

/// Waits on the children. When the first BEAM exits, every other child gets
/// SIGTERM, so a BEAM runs `init:stop/0` (SIGINT would leave it at its break
/// prompt), then SIGKILL if it is still running after `STOP_GRACE`. A dev
/// add-on exiting on its own is only reported. Returns the BEAM that exited
/// first.
fn supervise(processes: &mut [ChildProcess]) -> Option<(String, ExitStatus)> {
    let mut first_exit: Option<(String, ExitStatus)> = None;
    let mut stop_sent_at: Option<std::time::Instant> = None;
    loop {
        for process in processes
            .iter_mut()
            .filter(|process| process.exit.is_none())
        {
            if let Ok(Some(status)) = process.child.try_wait() {
                process.exit = Some(status);
                if process.critical {
                    first_exit.get_or_insert((process.label.clone(), status));
                } else if stop_sent_at.is_none() {
                    sub_warn(&format!(
                        "{} exited ({}); vehicle still running",
                        process.label, status
                    ));
                }
            }
        }
        if processes.iter().all(|process| process.exit.is_some()) {
            return first_exit;
        }
        if first_exit.is_some() {
            match stop_sent_at {
                None => {
                    signal_running(processes, libc::SIGTERM);
                    stop_sent_at = Some(std::time::Instant::now());
                }
                Some(sent_at) if sent_at.elapsed() > STOP_GRACE => {
                    signal_running(processes, libc::SIGKILL);
                }
                Some(_) => {}
            }
        }
        thread::sleep(std::time::Duration::from_millis(200));
    }
}

/// Stops the children started so far, for an error before supervision.
fn stop(processes: &mut [ChildProcess]) {
    signal_running(processes, libc::SIGTERM);
    for process in processes.iter_mut() {
        let _ = process.child.wait();
    }
}

/// Signals the children not yet reaped; a reaped child's pid may already
/// belong to another process.
fn signal_running(processes: &[ChildProcess], signal: libc::c_int) {
    for process in processes.iter().filter(|process| process.exit.is_none()) {
        unsafe { libc::kill(process.child.id() as libc::pid_t, signal) };
    }
}

/// A spawned child the run loop supervises. `critical` BEAMs drive the
/// loop's lifetime; dev add-ons are not critical.
struct ChildProcess {
    label: String,
    child: Child,
    critical: bool,
    exit: Option<ExitStatus>,
}

/// A dev add-on resolved into a launchable form: a firmware's declared
/// `DevAddon` with its directory made absolute and a display label.
struct Addon {
    /// Log prefix, `<family>-<name>` (e.g. "vms-dashboard").
    label: String,
    /// Absolute directory to run in.
    dir: PathBuf,
    /// Command (argv) that starts the dev process.
    run: Vec<String>,
    /// Optional install command (argv) for first run.
    install: Option<Vec<String>>,
    /// Optional path under `dir` whose presence means deps are installed.
    ready_marker: Option<String>,
    /// Optional one-line hint shown when the add-on starts.
    note: Option<String>,
}

/// The dev add-ons each firmware project declares in `dev_addons/0`,
/// labelled with the firmware family (the project dir's parent: "vms", …)
/// so add-ons from different firmwares don't collide in the logs.
fn discover_addons(roles: &[Role]) -> Result<Vec<Addon>> {
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut addons = Vec::new();
    for role in roles {
        if seen.contains(&role.cwd) {
            continue;
        }
        seen.push(role.cwd.clone());
        let family = role
            .cwd
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("addon")
            .to_string();
        for addon in vehicles::dev_addons(&role.cwd)? {
            let dir = role.cwd.join(&addon.dir);
            let dir = dir.canonicalize().unwrap_or(dir);
            addons.push(Addon {
                label: format!("{}-{}", family, addon.name),
                dir,
                run: addon.run,
                install: addon.install,
                ready_marker: addon.ready_marker,
                note: addon.note,
            });
        }
    }
    Ok(addons)
}

/// Drop add-ons whose toolchain (the `run` binary) is missing — warn, don't
/// fail. Install deps for any whose `ready_marker` is absent, and return the
/// launchable set. A failed install drops just that add-on; the BEAMs still
/// boot.
fn ensure_addon_deps(addons: Vec<Addon>) -> Vec<Addon> {
    let mut ready = Vec::new();
    let mut to_install = Vec::new();
    for addon in addons {
        if !tool_available(&addon.run[0]) {
            sub_warn(&format!(
                "{}: `{}` not found on PATH — skipping",
                addon.label, addon.run[0]
            ));
            continue;
        }
        let needs_install = match (&addon.ready_marker, &addon.install) {
            (Some(marker), Some(_)) => !addon.dir.join(marker).exists(),
            _ => false,
        };
        if needs_install {
            to_install.push(addon);
        } else {
            ready.push(addon);
        }
    }

    if to_install.is_empty() {
        return ready;
    }

    step(&format!(
        "Installing dev add-on dependencies ({} project(s))",
        to_install.len()
    ));
    for addon in to_install {
        let install = addon
            .install
            .clone()
            .expect("to_install implies install set");
        sub(&format!("{} ({})", install.join(" "), addon.label));
        let installed = Command::new(&install[0])
            .args(&install[1..])
            .current_dir(&addon.dir)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if installed {
            ready.push(addon);
        } else {
            sub_warn(&format!(
                "{}: `{}` failed — skipping",
                addon.label,
                install.join(" ")
            ));
        }
    }
    println!();
    ready
}

/// Whether a binary is on PATH: spawning is the check, as in `doctor`.
fn tool_available(name: &str) -> bool {
    Command::new(name)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

struct Role {
    /// Label used for the sname suffix and the log prefix (e.g. "vms",
    /// "infotainment", "vision", "bridge-radio_control").
    label: String,
    /// Directory to `cd` into before spawning the BEAM.
    cwd: PathBuf,
    /// Env vars passed to the BEAM (VEHICLE + optional
    /// BRIDGE_FIRMWARE_ID + CAN_NETWORK_MAPPINGS).
    env: Vec<(String, String)>,
}

fn enumerate_roles(root: &std::path::Path, vehicle: &Vehicle) -> Result<Vec<Role>> {
    // The Nerves `MIX_TARGET` is dropped; bridges get their host CAN mapping.
    let roles = firmware::roles_for(vehicle)?;
    let host_mappings = bridge_host_mappings(vehicle)?;

    roles
        .into_iter()
        .map(|role| {
            let role_firmware = firmware::resolve(vehicle, &role)?;
            let mut env: Vec<(String, String)> = role_firmware
                .env
                .into_iter()
                .filter(|(name, _)| name != "MIX_TARGET")
                .collect();
            if let Some(id) = firmware::bridge_id(&role) {
                if let Some(mapping) = host_mappings.get(id) {
                    env.push(("CAN_NETWORK_MAPPINGS".to_string(), mapping.clone()));
                }
            }
            Ok(Role {
                label: role,
                cwd: root.join(&role_firmware.firmware_dir),
                env,
            })
        })
        .collect()
}

/// Run `./build.sh` with `MIX_TARGET=host` once per firmware directory in
/// `roles`, in parallel. Roles sharing a directory (every bridge) share one
/// compile, shown as one pane: `bridges (radio_control, ros)`. A failure
/// bails before any BEAM is spawned; the other builds finish first, and the
/// first failure's log is printed.
fn ensure_built(roles: &[Role], vehicle: &Vehicle) -> Result<()> {
    let groups = build_groups(roles);

    let total: usize = groups.iter().map(|group| group.roles.len()).sum();
    step(&format!(
        "Building {} role(s) across {} firmware project(s)",
        total,
        groups.len()
    ));

    let lanes = groups
        .into_iter()
        .map(|group| {
            let pane = build_pane_label(&group);
            BuildLane {
                cwd: group.cwd,
                steps: vec![BuildStep {
                    panes: vec![pane],
                    env: HashMap::from([
                        ("MIX_TARGET".to_string(), "host".to_string()),
                        ("VEHICLE".to_string(), vehicle.module.clone()),
                    ]),
                }],
            }
        })
        .collect();

    build_runner::run_parallel(lanes)?;
    println!();
    Ok(())
}

/// A group of roles sharing a `build.sh` (all bridges roles share
/// `bridges/firmware`; vms, infotainment and vision are their own groups).
struct BuildGroup {
    cwd: PathBuf,
    /// Role labels in the order they were declared — drives pane order.
    roles: Vec<String>,
}

fn build_groups(roles: &[Role]) -> Vec<BuildGroup> {
    let mut groups: Vec<BuildGroup> = Vec::new();
    for role in roles {
        if let Some(group) = groups.iter_mut().find(|group| group.cwd == role.cwd) {
            group.roles.push(role.label.clone());
        } else {
            groups.push(BuildGroup {
                cwd: role.cwd.clone(),
                roles: vec![role.label.clone()],
            });
        }
    }
    groups
}

/// Label of a group's build pane: the role, or for several roles sharing a
/// compile, `bridges (radio_control, ros)`.
fn build_pane_label(group: &BuildGroup) -> String {
    if group.roles.len() == 1 {
        return group.roles[0].clone();
    }
    let family = group
        .cwd
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        .unwrap_or("bridges");
    let ids: Vec<&str> = group
        .roles
        .iter()
        .map(|role| role.strip_prefix("bridge-").unwrap_or(role))
        .collect();
    format!("{} ({})", family, ids.join(", "))
}

/// Ask the vehicle module for each bridge's host-side CAN mapping so the
/// shared bridges/firmware runtime.exs can pick it up via env.
fn bridge_host_mappings(vehicle: &Vehicle) -> Result<HashMap<String, String>> {
    let snippet = format!(
        r##"
vehicle = {module}
Code.ensure_loaded(vehicle)
if function_exported?(vehicle, :bridge_firmwares, 0) do
  vehicle.bridge_firmwares()
  |> Enum.map(fn {{id, entry}} ->
    host = get_in(entry, [:default_can_mapping, :host]) || ""
    "#{{id}}\t#{{host}}"
  end)
  |> Enum.join("\n")
  |> IO.puts()
end
"##,
        module = vehicle.module,
    );
    match vehicles::run_snippet(&vehicle.path, &snippet)? {
        None => Ok(HashMap::new()),
        Some(output) => {
            let mut mappings = HashMap::new();
            for line in output.lines().filter(|line| !line.is_empty()) {
                if let Some((id, mapping)) = line.split_once('\t') {
                    if !mapping.is_empty() {
                        mappings.insert(id.to_string(), mapping.to_string());
                    }
                }
            }
            Ok(mappings)
        }
    }
}

fn prefix_stream<R, W>(reader: R, label: &str, mut sink: W)
where
    R: std::io::Read + Send + 'static,
    W: Write + Send + 'static,
{
    // Logger's console format wraps each message in blank lines.
    for line in lossy_lines(BufReader::new(reader)) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        if is_iex_prompt_echo(&line) {
            continue;
        }
        let _ = writeln!(sink, "[{}] {}", label, line);
        let _ = sink.flush();
    }
}

fn short_path(path: &std::path::Path, root: &std::path::Path) -> String {
    path.strip_prefix(root)
        .map(|relative| relative.display().to_string())
        .unwrap_or_else(|_| path.display().to_string())
}

/// An IEx prompt or a bare `:ok`, the only lines an `attach` session can
/// leave in a BEAM's output; error reports and stack frames are kept.
fn is_iex_prompt_echo(line: &str) -> bool {
    let stripped = strip_ansi(line);
    let trimmed = stripped.trim();
    trimmed.starts_with("iex(") || trimmed.starts_with("...(") || trimmed == ":ok"
}

#[cfg(test)]
mod tests {
    use super::{build_pane_label, is_iex_prompt_echo, supervise, BuildGroup, ChildProcess};
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::Instant;

    fn spawn(label: &str, script: &str, critical: bool) -> ChildProcess {
        ChildProcess {
            label: label.to_string(),
            child: Command::new("sh").args(["-c", script]).spawn().unwrap(),
            critical,
            exit: None,
        }
    }

    #[test]
    fn a_beam_exiting_stops_the_others_and_is_reported() {
        let started = Instant::now();
        let mut processes = vec![
            spawn("vms", "exit 3", true),
            spawn("bridge-ros", "sleep 30", true),
            spawn("dashboard", "sleep 30", false),
        ];
        let (label, status) = supervise(&mut processes).expect("a BEAM exited");
        assert_eq!(label, "vms");
        assert_eq!(status.code(), Some(3));
        assert!(processes.iter().all(|process| process.exit.is_some()));
        assert!(started.elapsed().as_secs() < 5);
    }

    #[test]
    fn a_beam_ignoring_sigterm_gets_sigkill() {
        let started = Instant::now();
        let mut processes = vec![
            spawn("vms", "exit 1", true),
            spawn("stuck", "trap '' TERM; sleep 60", true),
        ];
        supervise(&mut processes).expect("a BEAM exited");
        assert!(processes.iter().all(|process| process.exit.is_some()));
        assert!(started.elapsed().as_secs() < 20);
    }

    #[test]
    fn errors_and_stack_frames_are_not_taken_for_iex_echo() {
        assert!(is_iex_prompt_echo("iex(ovcs-mini-vms@host)3> :ok"));
        assert!(is_iex_prompt_echo(":ok"));
        assert!(!is_iex_prompt_echo(
            "** (Mix) Could not start application vms_core: exited in: ..."
        ));
        assert!(!is_iex_prompt_echo(
            "    (vms_core 0.1.0) lib/vms_core/application.ex:12: VmsCore.Application.start/2"
        ));
        assert!(!is_iex_prompt_echo("Compiling 3 files (.ex)"));
    }

    fn build_group(cwd: &str, roles: &[&str]) -> BuildGroup {
        BuildGroup {
            cwd: PathBuf::from(cwd),
            roles: roles.iter().map(|role| role.to_string()).collect(),
        }
    }

    #[test]
    fn a_firmware_built_for_one_role_is_labelled_with_the_role() {
        let group = build_group("/repo/vms/firmware", &["vms"]);
        assert_eq!(build_pane_label(&group), "vms");
    }

    #[test]
    fn bridges_sharing_a_build_are_labelled_with_their_ids() {
        let group = build_group(
            "/repo/bridges/firmware",
            &["bridge-radio_control", "bridge-ros"],
        );
        assert_eq!(build_pane_label(&group), "bridges (radio_control, ros)");
    }
}
