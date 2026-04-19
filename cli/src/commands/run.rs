use anyhow::{anyhow, Context, Result};
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;

use crate::commands::can::ensure_host_can;
use crate::firmware;
use crate::prompt::choose_vehicle;
use crate::repo_root::repo_root;
use crate::vehicles::{self, Vehicle};

pub fn run(vehicle_arg: Option<String>) -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    let vehicle = match vehicle_arg {
        Some(dir) => list
            .into_iter()
            .find(|v| v.dir == dir)
            .ok_or_else(|| anyhow!("Unknown vehicle {}", dir))?,
        None => choose_vehicle(&list)?,
    };

    ensure_host_can(&vehicle)?;

    let roles = enumerate_roles(&root, &vehicle)?;
    if roles.is_empty() {
        anyhow::bail!("no roles to spawn for vehicle {}", vehicle.dir);
    }

    println!();
    println!("{}", "Booting vehicle locally…".bold());
    println!(
        "{}",
        format!(
            "→ {} BEAMs joined by OvcsBus.Cluster (Erlang distribution)",
            roles.len()
        )
        .cyan()
    );
    for r in &roles {
        println!(
            "{}",
            format!(
                "   • {}-{}  (cd {})",
                vehicle.dir,
                r.label,
                short_path(&r.cwd, &root)
            )
            .dimmed()
        );
    }
    println!(
        "{}",
        "Attach a shell with `./ovcs attach` in another terminal. Ctrl-C to stop.".dimmed()
    );
    println!();

    // Each unique firmware directory (vms/firmware, infotainment/firmware,
    // bridges/firmware) needs `mix deps.get` once before any BEAM spawned
    // from it will compile. Run this first-and-synchronously so missing deps
    // surface as a single clean error rather than N parallel failures.
    ensure_deps(&roles)?;

    let mut children: Vec<(String, Child)> = Vec::new();

    for role in &roles {
        let sname = format!("{}-{}", vehicle.dir, sname_safe(&role.label));
        let mut cmd = Command::new("elixir");
        cmd.args([
            "--sname",
            &sname,
            "--cookie",
            "ovcs",
            "-S",
            "mix",
            "run",
            "--no-halt",
        ])
        .current_dir(&role.cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
        for (k, v) in &role.env {
            cmd.env(k, v);
        }
        let mut child = cmd
            .spawn()
            .with_context(|| format!("failed to spawn elixir for role {}", role.label))?;

        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let label_out = role.label.clone();
        let label_err = role.label.clone();
        thread::spawn(move || prefix_stream(stdout, &label_out, std::io::stdout()));
        thread::spawn(move || prefix_stream(stderr, &label_err, std::io::stderr()));

        children.push((role.label.clone(), child));
    }

    // Happy path: Ctrl-C propagates SIGINT to the whole process group; the
    // Rust parent exits, the BEAMs are reaped by their parents' death. Crash
    // path: if any child dies early (BEAM crash, compile failure, …), don't
    // leave the others running — send SIGTERM to each survivor so BEAM runs
    // `init:stop/0` and shuts down cleanly. (SIGINT would trip the BEAM's
    // JCL break handler and leave each child sitting at an interactive
    // prompt.)
    let mut propagated = false;
    loop {
        let mut any_dead = false;
        let mut all_dead = true;
        for (_label, child) in children.iter_mut() {
            match child.try_wait() {
                Ok(Some(_)) => {
                    any_dead = true;
                }
                Ok(None) => {
                    all_dead = false;
                }
                Err(_) => {}
            }
        }
        if all_dead {
            break;
        }
        if any_dead && !propagated {
            for (_label, child) in children.iter() {
                // try_wait has set the exit status on already-dead children;
                // kill(2) on a reaped pid returns ESRCH, which we ignore.
                unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
            }
            propagated = true;
        }
        thread::sleep(std::time::Duration::from_millis(200));
    }

    Ok(())
}

struct Role {
    /// Label used for the sname suffix and the log prefix (e.g. "vms",
    /// "infotainment", "bridge-radio_control").
    label: String,
    /// Directory to `cd` into before spawning the BEAM.
    cwd: PathBuf,
    /// Env vars passed to the BEAM (VEHICLE + optional
    /// BRIDGE_FIRMWARE_ID + CAN_NETWORK_MAPPINGS).
    env: Vec<(String, String)>,
}

fn enumerate_roles(root: &std::path::Path, vehicle: &Vehicle) -> Result<Vec<Role>> {
    // Delegate firmware → (dir, env) resolution to `firmware::resolve`
    // so the mapping lives in one place. We drop `MIX_TARGET` (baked in
    // for cross-compilation, irrelevant on host dev) and layer host CAN
    // mappings onto bridge roles.
    let applications = firmware::applications_for(vehicle)?;
    let host_mappings = bridge_host_mappings(vehicle).unwrap_or_default();

    applications
        .into_iter()
        .map(|app| {
            let res = firmware::resolve(vehicle, &app)?;
            let label = match app.as_str() {
                "vms" | "infotainment" => app.clone(),
                bridge_id => format!("bridge-{}", bridge_id),
            };
            let mut env: Vec<(String, String)> = res
                .env
                .into_iter()
                .filter(|(k, _)| k != "MIX_TARGET")
                .collect();
            if let Some(mapping) = host_mappings.get(&app) {
                env.push(("CAN_NETWORK_MAPPINGS".to_string(), mapping.clone()));
            }
            Ok(Role {
                label,
                cwd: root.join(&res.firmware_dir),
                env,
            })
        })
        .collect()
}

/// Run `mix deps.get` once per unique firmware directory in `roles`.
/// Inherits stdio so the user sees the fetch output directly. If any dep
/// fetch fails we bail before spawning any BEAM.
fn ensure_deps(roles: &[Role]) -> Result<()> {
    let mut seen: std::collections::HashSet<PathBuf> = Default::default();
    for role in roles {
        if !seen.insert(role.cwd.clone()) {
            continue;
        }

        let label = role
            .cwd
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("firmware");
        let parent_label = role
            .cwd
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let display = if parent_label.is_empty() {
            label.to_string()
        } else {
            format!("{}/{}", parent_label, label)
        };

        println!("{}", format!("• mix deps.get in {}", display).dimmed());

        let status = Command::new("mix")
            .arg("deps.get")
            .current_dir(&role.cwd)
            .status()
            .with_context(|| format!("failed to invoke mix in {}", role.cwd.display()))?;

        if !status.success() {
            anyhow::bail!(
                "mix deps.get failed in {} (exit {:?})",
                role.cwd.display(),
                status.code()
            );
        }
    }
    println!();
    Ok(())
}

/// Ask the vehicle module for each bridge's host-side CAN mapping so the
/// shared bridges/firmware runtime.exs can pick it up via env.
fn bridge_host_mappings(vehicle: &Vehicle) -> Result<HashMap<String, String>> {
    let snippet = format!(
        r##"
m = {module}
Code.ensure_loaded(m)
if function_exported?(m, :bridge_firmwares, 0) do
  m.bridge_firmwares()
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
    match vehicles::run_snippet_public(&vehicle.path, &snippet)? {
        None => Ok(HashMap::new()),
        Some(output) => {
            let mut map = HashMap::new();
            for line in output.lines().filter(|l| !l.is_empty()) {
                if let Some((id, mapping)) = line.split_once('\t') {
                    if !mapping.is_empty() {
                        map.insert(id.to_string(), mapping.to_string());
                    }
                }
            }
            Ok(map)
        }
    }
}

fn prefix_stream<R, W>(reader: R, label: &str, mut sink: W)
where
    R: std::io::Read + Send + 'static,
    W: Write + Send + 'static,
{
    let buf = BufReader::new(reader);
    for line in buf.lines().map_while(|l| l.ok()) {
        let _ = writeln!(sink, "[{}] {}", label, line);
        let _ = sink.flush();
    }
}

fn sname_safe(label: &str) -> String {
    label.replace('_', "-")
}

fn short_path(p: &std::path::Path, root: &std::path::Path) -> String {
    p.strip_prefix(root)
        .map(|r| r.display().to_string())
        .unwrap_or_else(|_| p.display().to_string())
}
