use anyhow::{Context, Result, anyhow, bail};
use owo_colors::OwoColorize;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::{Duration, Instant};

use crate::commands::can::ensure_host_can;
use crate::commands::run_ui::{self, Msg};
use crate::prompt::choose;
use crate::repo_root::repo_root;
use crate::vehicles;

pub fn run(vehicle_arg: Option<String>) -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    let names: Vec<String> = list.iter().map(|v| v.dir.clone()).collect();
    let vehicle_dir = match vehicle_arg {
        Some(v) => v,
        None => choose("vehicle", &names)?,
    };
    let vehicle = list
        .into_iter()
        .find(|v| v.dir == vehicle_dir)
        .ok_or_else(|| anyhow!("Unknown vehicle {}", vehicle_dir))?;

    ensure_host_can(&vehicle)?;

    let cwd = root.join("vehicles").join(&vehicle.dir);
    let hostname = hostname_short()?;
    let cookie = "ovcs".to_string();
    let app_node = format!("ovcs_{}", vehicle.dir);
    let shell_node = format!("ovcs_dbg_{}", std::process::id());

    println!();
    println!("{}", "Booting vehicle locally…".bold());
    println!(
        "{}{}",
        format!("→ elixir --sname {} -S mix run --no-halt", app_node).cyan(),
        format!("  (cd {})", cwd.display()).dimmed()
    );

    let (tx, rx) = mpsc::channel::<Msg>();

    // Start the app: mix run --no-halt (no iex prompt — clean stdout).
    let mut app = Command::new("elixir")
        .args([
            "--sname", &app_node,
            "--cookie", &cookie,
            "-S", "mix", "run", "--no-halt",
        ])
        .current_dir(&cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn elixir")?;

    let app_stdout = app.stdout.take().unwrap();
    let app_stderr = app.stderr.take().unwrap();
    spawn_reader(app_stdout, tx.clone(), Msg::LogLine);
    spawn_reader(app_stderr, tx.clone(), Msg::LogLine);

    // Tell the UI when the app exits unexpectedly.
    {
        let tx = tx.clone();
        let app_pid = app.id();
        thread::spawn(move || {
            // Poll the /proc entry; simpler than juggling the Child across threads.
            loop {
                thread::sleep(Duration::from_millis(500));
                if !pid_alive(app_pid) {
                    let _ = tx.send(Msg::AppExited);
                    return;
                }
            }
        });
    }

    // Wait for the BEAM node to register with EPMD before spawning remsh.
    let full_node = format!("{}@{}", app_node, hostname);
    if let Err(e) = wait_for_node(&app_node, Duration::from_secs(30), &tx) {
        let _ = app.kill();
        bail!("BEAM node {} didn't come up: {}", full_node, e);
    }

    // Start the remote shell. `stdbuf -oL -eL` forces line buffering so
    // responses show up immediately in the UI — without a tty, iex
    // otherwise block-buffers its stdout.
    let mut shell = Command::new("stdbuf")
        .args([
            "-oL", "-eL",
            "iex",
            "--sname", &shell_node,
            "--cookie", &cookie,
            "--remsh", &full_node,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn iex --remsh")?;

    let shell_stdout = shell.stdout.take().unwrap();
    let shell_stderr = shell.stderr.take().unwrap();
    spawn_reader(shell_stdout, tx.clone(), Msg::ShellLine);
    spawn_reader(shell_stderr, tx.clone(), Msg::ShellLine);
    let shell_stdin = shell.stdin.take().unwrap();

    // Hand off to the UI. On exit we kill both children.
    let ui_result = run_ui::run(rx, shell_stdin, &full_node);

    let _ = shell.kill();
    let _ = shell.wait();
    // SIGINT the BEAM first (gives OTP time to shut down cleanly);
    // if still alive after a second, SIGKILL.
    let _ = send_sigint(&app);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match app.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() >= deadline => {
                let _ = app.kill();
                let _ = app.wait();
                break;
            }
            Ok(None) => thread::sleep(Duration::from_millis(100)),
            Err(_) => break,
        }
    }

    ui_result
}

fn spawn_reader<R, F>(reader: R, tx: Sender<Msg>, wrap: F)
where
    R: std::io::Read + Send + 'static,
    F: Fn(String) -> Msg + Send + 'static,
{
    thread::spawn(move || {
        let buf = BufReader::new(reader);
        for line in buf.lines().map_while(|l| l.ok()) {
            if tx.send(wrap(line)).is_err() {
                break;
            }
        }
    });
}

fn hostname_short() -> Result<String> {
    let out = Command::new("hostname")
        .arg("-s")
        .output()
        .context("failed to invoke hostname -s")?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn pid_alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{}", pid)).exists()
}

fn wait_for_node(short_name: &str, timeout: Duration, tx: &Sender<Msg>) -> Result<()> {
    let _ = tx.send(Msg::LogLine(format!(
        "[ovcs] waiting for BEAM node {} to register with epmd…",
        short_name
    )));
    let start = Instant::now();
    let needle = format!("name {} at", short_name);
    loop {
        if let Ok(out) = Command::new("epmd").arg("-names").output() {
            let s = String::from_utf8_lossy(&out.stdout);
            if s.contains(&needle) {
                let _ = tx.send(Msg::LogLine(
                    "[ovcs] node registered; opening remote shell".to_string(),
                ));
                return Ok(());
            }
        }
        if start.elapsed() > timeout {
            bail!("timed out after {:?}", timeout);
        }
        thread::sleep(Duration::from_millis(250));
    }
}

fn send_sigint(child: &Child) -> std::io::Result<()> {
    // libc-free SIGINT via /bin/kill; acceptable for a single one-shot.
    let pid = child.id();
    Command::new("kill")
        .args(["-INT", &pid.to_string()])
        .status()
        .map(|_| ())
}
