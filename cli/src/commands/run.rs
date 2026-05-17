use anyhow::{Context, Result};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, IsTerminal, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::ansi::{is_blank_after_ansi, strip_ansi};
use crate::commands::attach::is_iex_noise;
use crate::commands::can::ensure_host_can;
use crate::firmware;
use crate::repo_root::repo_root;
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub};
use crate::vehicles::{self, Vehicle};

pub fn run(vehicle_arg: Option<String>) -> Result<()> {
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
        .map(|r| r.label.len() + vehicle.dir.len() + 1)
        .max()
        .unwrap_or(0);
    for r in &roles {
        let sname = format!("{}-{}", vehicle.dir, r.label);
        sub(&format!(
            "{:<width$}  {}",
            sname,
            short_path(&r.cwd, &root),
            width = sname_width
        ));
    }
    sub("Attach with `./ovcs attach` in another terminal · Ctrl-C to stop.");
    println!();

    // Warm up each unique firmware directory's `_build/dev/` via its own
    // `build.sh MIX_TARGET=host` — same script the deployed flow uses,
    // just in host mode. Keeps prep logic (deps.get + compile, plus any
    // future firmware-project-specific steps) in one place per firmware
    // rather than split between the script and the CLI.
    ensure_built(&roles, &vehicle)?;

    let mut children: Vec<(String, Child)> = Vec::new();

    for role in &roles {
        let sname = format!("{}-{}", vehicle.dir, sname_safe(&role.label));
        let mut cmd = Command::new("elixir");
        cmd.args([
            "--sname",
            &sname,
            "--cookie",
            "ovcs",
            // BEAM disables `IO.ANSI` when stdout is piped; force it back
            // on so Logger emits coloured `[info]` / `[debug]` etc. into
            // our line-prefixing pipe.
            "--erl",
            "-elixir ansi_enabled true",
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
            let mut env: Vec<(String, String)> = res
                .env
                .into_iter()
                .filter(|(k, _)| k != "MIX_TARGET")
                .collect();
            if let Some(id) = firmware::bridge_id(&app) {
                if let Some(mapping) = host_mappings.get(id) {
                    env.push(("CAN_NETWORK_MAPPINGS".to_string(), mapping.clone()));
                }
            }
            Ok(Role {
                label: app,
                cwd: root.join(&res.firmware_dir),
                env,
            })
        })
        .collect()
}

/// Invoke `./build.sh` with `MIX_TARGET=host` once per unique firmware
/// directory in `roles` — in parallel, one thread per firmware. Multiple
/// roles can share a cwd (every bridge role points at `bridges/firmware`
/// on host) so we run a single build per cwd but expose one pane per
/// role so the user sees each role prepare separately.
///
/// On a TTY each role gets its own live spinner pane (buildkit-style)
/// showing the shared build's latest log line; on failure that group's
/// full buffered output is dumped afterwards. When stdout isn't a TTY
/// we fall back to the line-prefixed `[<role>:build] …` interleaved
/// stream so CI logs stay greppable. `build.sh` handles `deps.get`
/// then `compile` (host) or `firmware` (target); calling it here keeps
/// build / run on the same entry point. Any non-zero exit bails before
/// a single BEAM is spawned; remaining builds are allowed to finish so
/// the user sees every failure, not just the first.
fn ensure_built(roles: &[Role], vehicle: &Vehicle) -> Result<()> {
    let groups = build_groups(roles);

    for g in &groups {
        let script = g.cwd.join("build.sh");
        if !script.exists() {
            anyhow::bail!(
                "expected build.sh at {} — can't prepare host build",
                script.display()
            );
        }
    }

    let total: usize = groups.iter().map(|g| g.roles.len()).sum();
    step(&format!(
        "Building {} role(s) across {} firmware project(s)",
        total,
        groups.len()
    ));

    if std::io::stdout().is_terminal() {
        ensure_built_panes(&groups, vehicle)
    } else {
        ensure_built_plain(&groups, vehicle)
    }
}

/// A group of roles sharing a `build.sh` (all bridges roles share
/// `bridges/firmware`; vms and infotainment are their own groups).
struct BuildGroup {
    cwd: PathBuf,
    /// Role labels in the order they were declared — drives pane order.
    roles: Vec<String>,
}

fn build_groups(roles: &[Role]) -> Vec<BuildGroup> {
    let mut groups: Vec<BuildGroup> = Vec::new();
    for role in roles {
        if let Some(g) = groups.iter_mut().find(|g| g.cwd == role.cwd) {
            g.roles.push(role.label.clone());
        } else {
            groups.push(BuildGroup {
                cwd: role.cwd.clone(),
                roles: vec![role.label.clone()],
            });
        }
    }
    groups
}

fn ensure_built_panes(groups: &[BuildGroup], vehicle: &Vehicle) -> Result<()> {
    let mp = MultiProgress::new();
    let tag_width = groups
        .iter()
        .flat_map(|g| g.roles.iter())
        .map(|r| r.len())
        .max()
        .unwrap_or(0);
    // Two leading spaces line the spinner up with the `·` column of the
    // sub() sub-items just above it, so the whole block reads as one
    // indented "things we're doing" list.
    let style = ProgressStyle::with_template("  {spinner:.green} {prefix:.cyan.bold}  {wide_msg}")
        .expect("static template")
        .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "✓"]);

    let mut handles: Vec<thread::JoinHandle<BuildOutcome>> = Vec::new();
    for g in groups {
        // One spinner per role in the group so each role reads as its
        // own line, even though they all track the same build process.
        let bars: Vec<ProgressBar> = g
            .roles
            .iter()
            .map(|role| {
                let bar = mp.add(ProgressBar::new_spinner());
                bar.set_style(style.clone());
                bar.set_prefix(format!("{:<width$}", role, width = tag_width));
                bar.set_message("starting…".to_string());
                bar.enable_steady_tick(std::time::Duration::from_millis(100));
                bar
            })
            .collect();
        let cwd = g.cwd.clone();
        let module = vehicle.module.clone();
        let group_label = g.roles.join("+");

        handles.push(thread::spawn(move || {
            run_group_pane(group_label, cwd, module, bars)
        }));
    }

    let mut first_err: Option<BuildFailure> = None;
    for h in handles {
        match h.join().unwrap() {
            Ok(()) => {}
            Err(e) => {
                if first_err.is_none() {
                    first_err = Some(e);
                }
            }
        }
    }

    // Drop MultiProgress so subsequent eprintln! aren't tangled with
    // its terminal state.
    drop(mp);

    if let Some(f) = first_err {
        eprintln!();
        eprintln!("{}", format!("── {} log ──", f.label).red().bold());
        for line in &f.lines {
            eprintln!("{}", line);
        }
        anyhow::bail!("{} failed (exit {:?})", f.label, f.code);
    }

    println!();
    Ok(())
}

type BuildOutcome = Result<(), BuildFailure>;

struct BuildFailure {
    label: String,
    lines: Vec<String>,
    code: Option<i32>,
}

fn run_group_pane(
    group_label: String,
    cwd: PathBuf,
    module: String,
    bars: Vec<ProgressBar>,
) -> BuildOutcome {
    let script = cwd.join("build.sh");
    let label = format!("{}:build", group_label);
    let buf: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let finish_all = |bars: &[ProgressBar], msg: String| {
        for bar in bars {
            bar.finish_with_message(msg.clone());
        }
    };

    let mut child = match Command::new(&script)
        .current_dir(&cwd)
        .env("MIX_TARGET", "host")
        .env("VEHICLE", &module)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            let msg = format!("spawn failed: {}", e);
            finish_all(&bars, msg.clone());
            return Err(BuildFailure {
                label,
                lines: vec![msg],
                code: None,
            });
        }
    };

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let bars_arc: Arc<Vec<ProgressBar>> = Arc::new(bars);
    let b1 = Arc::clone(&bars_arc);
    let buf1 = Arc::clone(&buf);
    let t1 = thread::spawn(move || capture_stream(stdout, &b1, &buf1));
    let b2 = Arc::clone(&bars_arc);
    let buf2 = Arc::clone(&buf);
    let t2 = thread::spawn(move || capture_stream(stderr, &b2, &buf2));

    let status = child.wait();
    let _ = t1.join();
    let _ = t2.join();

    let lines = buf.lock().unwrap().clone();
    match status {
        Ok(s) if s.success() => {
            finish_all(&bars_arc, "done".green().to_string());
            Ok(())
        }
        Ok(s) => {
            finish_all(
                &bars_arc,
                format!("FAILED (exit {})", s.code().unwrap_or(-1))
                    .red()
                    .to_string(),
            );
            Err(BuildFailure {
                label,
                lines,
                code: s.code(),
            })
        }
        Err(e) => {
            finish_all(&bars_arc, format!("wait failed: {}", e).red().to_string());
            Err(BuildFailure {
                label,
                lines,
                code: None,
            })
        }
    }
}

/// Fan one build's output across every pane in its group — each role
/// shows the same live log line, and we also buffer every line so a
/// failed build can dump its full log afterwards.
fn capture_stream<R>(reader: R, bars: &[ProgressBar], buf: &Arc<Mutex<Vec<String>>>)
where
    R: std::io::Read + Send + 'static,
{
    let buf_reader = BufReader::new(reader);
    for line in buf_reader.lines().map_while(|l| l.ok()) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        let stripped = strip_ansi(&line);
        let display = stripped.trim_start().to_string();
        for bar in bars {
            bar.set_message(display.clone());
        }
        buf.lock().unwrap().push(line);
    }
}

fn ensure_built_plain(groups: &[BuildGroup], vehicle: &Vehicle) -> Result<()> {
    let mut handles: Vec<thread::JoinHandle<Result<()>>> = Vec::new();
    for g in groups {
        let cwd = g.cwd.clone();
        let module = vehicle.module.clone();
        // `vms` or `bridge-radio_control+bridge-ros` — the plain path
        // reduces to a single prefix per shared build.
        let label = format!("{}:build", g.roles.join("+"));
        handles.push(thread::spawn(move || -> Result<()> {
            let script = cwd.join("build.sh");
            let mut child = Command::new(&script)
                .current_dir(&cwd)
                .env("MIX_TARGET", "host")
                .env("VEHICLE", &module)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .with_context(|| format!("failed to invoke {}", script.display()))?;

            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();
            let label_out = label.clone();
            let label_err = label.clone();
            let t1 = thread::spawn(move || prefix_stream(stdout, &label_out, std::io::stdout()));
            let t2 = thread::spawn(move || prefix_stream(stderr, &label_err, std::io::stderr()));

            let status = child.wait()?;
            let _ = t1.join();
            let _ = t2.join();

            if !status.success() {
                anyhow::bail!("{} failed (exit {:?})", label, status.code());
            }
            Ok(())
        }));
    }

    let mut first_err: Option<anyhow::Error> = None;
    for h in handles {
        match h.join().unwrap() {
            Ok(()) => {}
            Err(e) => {
                if first_err.is_none() {
                    first_err = Some(e);
                }
            }
        }
    }

    if let Some(e) = first_err {
        return Err(e);
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
    match vehicles::run_snippet(&vehicle.path, &snippet)? {
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
    // Elixir's default Logger console format brackets each message with
    // a leading and trailing newline. Piped through line-prefixing that
    // becomes a pair of `[label] ` blanks around every log entry. Skip
    // lines whose ANSI-stripped content is empty so the merged view
    // stays dense.
    let buf = BufReader::new(reader);
    for line in buf.lines().map_while(|l| l.ok()) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        // When `./ovcs attach` connects, the remote BEAM's IEx echoes the
        // remsh's typed input (our base64 init wrapper) plus its own
        // prompt to local stdout — `run` captures that via the BEAM's
        // pipe and would prefix it with `[label]`. Drop those lines so
        // the run window stays free of attach plumbing.
        if is_iex_noise(&line) {
            continue;
        }
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
