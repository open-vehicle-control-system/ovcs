//! Parallel `build.sh` executor shared by `build --all` and `run`'s
//! host-build warm-up.
//!
//! The unit of parallelism is a [`BuildLane`] — one firmware directory.
//! Lanes run concurrently, but the [`BuildStep`]s inside a lane run
//! sequentially: two builds in the same firmware dir (e.g. the rpi3a and
//! rpi4 bridge targets, both under `bridges/firmware`) would otherwise
//! race on that project's shared `deps/` and `mix.lock`. Cross-lane builds
//! still touch the same `vehicles/<dir>` host app, but Mix's build-path
//! lock (Elixir ≥ 1.15) serialises those compiles safely.
//!
//! On a TTY every step's `panes` render as live spinner lines showing the
//! build's latest log line. A failure skips the later steps of its lane.
//! Off a TTY (CI, pipes) output is line-prefixed `[<label>] …` instead.
//!
//! A failing lane doesn't abort the others; the first failure's log is
//! printed at the end.

use anyhow::{bail, Result};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::io::{BufReader, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::ansi::{is_blank_after_ansi, strip_ansi};
use crate::lines::lossy_lines;

/// One `build.sh` invocation in a lane's directory, with its env.
/// `panes` are the labels of the progress lines that track it.
pub struct BuildStep {
    pub panes: Vec<String>,
    pub env: HashMap<String, String>,
}

/// One firmware directory and the steps to run in it, in order. Steps run
/// sequentially; lanes run in parallel.
pub struct BuildLane {
    pub cwd: PathBuf,
    pub steps: Vec<BuildStep>,
}

/// Run every lane concurrently (steps within a lane sequentially). Returns
/// `Ok` only if all steps succeed; on any failure the first failing step's
/// full log is printed and an error is returned.
pub fn run_parallel(lanes: Vec<BuildLane>) -> Result<()> {
    for lane in &lanes {
        let script = lane.cwd.join("build.sh");
        if !script.exists() {
            bail!("expected build.sh at {} — can't build", script.display());
        }
    }

    if std::io::stdout().is_terminal() {
        run_panes(lanes)
    } else {
        run_plain(lanes)
    }
}

struct Failure {
    label: String,
    lines: Vec<String>,
    code: Option<i32>,
}

fn run_panes(lanes: Vec<BuildLane>) -> Result<()> {
    let progress = MultiProgress::new();
    let tag_width = lanes
        .iter()
        .flat_map(|lane| lane.steps.iter())
        .flat_map(|step| step.panes.iter())
        .map(|pane| pane.len())
        .max()
        .unwrap_or(0);
    // Two leading spaces line the spinner up with the `·` column of the
    // ui::sub() items above it, so the whole block reads as one list.
    let style = ProgressStyle::with_template("  {spinner:.green} {prefix:.cyan.bold}  {wide_msg}")
        .expect("static template")
        .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "✓"]);

    let mut handles: Vec<thread::JoinHandle<Result<(), Failure>>> = Vec::new();
    for lane in lanes {
        // Pre-create every step's bars up front (in lane/step/pane order)
        // so the layout is stable; steps not yet running read "queued…".
        let step_bars: Vec<Vec<ProgressBar>> = lane
            .steps
            .iter()
            .map(|step| {
                step.panes
                    .iter()
                    .map(|pane| {
                        let bar = progress.add(ProgressBar::new_spinner());
                        bar.set_style(style.clone());
                        bar.set_prefix(format!("{:<width$}", pane, width = tag_width));
                        bar.set_message("queued…".to_string());
                        bar
                    })
                    .collect()
            })
            .collect();
        let cwd = lane.cwd.clone();
        let steps = lane.steps;
        handles.push(thread::spawn(move || {
            run_lane_panes(&cwd, steps, step_bars)
        }));
    }

    let mut first_failure: Option<Failure> = None;
    for handle in handles {
        if let Err(failure) = handle.join().unwrap() {
            if first_failure.is_none() {
                first_failure = Some(failure);
            }
        }
    }

    // Drop MultiProgress before any eprintln! so its terminal state isn't
    // tangled with the dumped log.
    drop(progress);

    if let Some(failure) = first_failure {
        eprintln!();
        eprintln!("{}", format!("── {} log ──", failure.label).red().bold());
        for line in &failure.lines {
            eprintln!("{}", line);
        }
        bail!("{} failed (exit {:?})", failure.label, failure.code);
    }

    Ok(())
}

fn run_lane_panes(
    cwd: &Path,
    steps: Vec<BuildStep>,
    step_bars: Vec<Vec<ProgressBar>>,
) -> Result<(), Failure> {
    for (index, step) in steps.into_iter().enumerate() {
        let bars = &step_bars[index];
        for bar in bars {
            bar.set_message("starting…".to_string());
            bar.enable_steady_tick(Duration::from_millis(100));
        }
        if let Err(failure) = run_step_panes(cwd, &step.env, bars) {
            // The failed step left the shared dir in an unknown state.
            for later in &step_bars[index + 1..] {
                for bar in later {
                    bar.finish_with_message("skipped".dimmed().to_string());
                }
            }
            return Err(failure);
        }
    }
    Ok(())
}

fn run_step_panes(
    cwd: &Path,
    env: &HashMap<String, String>,
    bars: &[ProgressBar],
) -> Result<(), Failure> {
    let label = bars
        .iter()
        .map(|bar| bar.prefix().trim_end().to_string())
        .collect::<Vec<_>>()
        .join("+");
    let log_lines: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let start = Instant::now();
    let finish_all = |message: String| {
        for bar in bars {
            bar.finish_with_message(message.clone());
        }
    };

    let mut child = match spawn_build(cwd, env) {
        Ok(child) => child,
        Err(error) => {
            let message = format!("spawn failed: {}", error);
            finish_all(message.clone().red().to_string());
            return Err(Failure {
                label,
                lines: vec![message],
                code: None,
            });
        }
    };

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let shared_bars: Arc<Vec<ProgressBar>> = Arc::new(bars.to_vec());
    let stdout_bars = Arc::clone(&shared_bars);
    let stdout_log = Arc::clone(&log_lines);
    let stdout_reader = thread::spawn(move || capture_stream(stdout, &stdout_bars, &stdout_log));
    let stderr_bars = Arc::clone(&shared_bars);
    let stderr_log = Arc::clone(&log_lines);
    let stderr_reader = thread::spawn(move || capture_stream(stderr, &stderr_bars, &stderr_log));

    let status = child.wait();
    let _ = stdout_reader.join();
    let _ = stderr_reader.join();

    let lines = log_lines.lock().unwrap().clone();
    let elapsed = fmt_elapsed(start.elapsed());
    match status {
        Ok(status) if status.success() => {
            finish_all(format!("done ({})", elapsed).green().to_string());
            Ok(())
        }
        Ok(status) => {
            finish_all(
                format!("FAILED (exit {}, {})", status.code().unwrap_or(-1), elapsed)
                    .red()
                    .to_string(),
            );
            Err(Failure {
                label,
                lines,
                code: status.code(),
            })
        }
        Err(error) => {
            finish_all(format!("wait failed: {}", error).red().to_string());
            Err(Failure {
                label,
                lines,
                code: None,
            })
        }
    }
}

/// Fan one build's output across every pane tracking it — each pane shows
/// the same live log line — while buffering every line so a failed build
/// can dump its full log afterwards.
fn capture_stream<R>(reader: R, bars: &[ProgressBar], log_lines: &Arc<Mutex<Vec<String>>>)
where
    R: std::io::Read + Send + 'static,
{
    for line in lossy_lines(BufReader::new(reader)) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        let display = strip_ansi(&line).trim_start().to_string();
        for bar in bars {
            bar.set_message(display.clone());
        }
        log_lines.lock().unwrap().push(line);
    }
}

fn run_plain(lanes: Vec<BuildLane>) -> Result<()> {
    let mut handles: Vec<thread::JoinHandle<Result<(), Failure>>> = Vec::new();
    for lane in lanes {
        handles.push(thread::spawn(move || {
            for step in &lane.steps {
                let label = step.panes.join("+");
                println!("[{}] starting build…", label);

                let mut child = match spawn_build(&lane.cwd, &step.env) {
                    Ok(child) => child,
                    Err(error) => {
                        return Err(Failure {
                            label,
                            lines: vec![format!("spawn failed: {}", error)],
                            code: None,
                        })
                    }
                };

                let stdout = child.stdout.take().unwrap();
                let stderr = child.stderr.take().unwrap();
                let stdout_label = label.clone();
                let stderr_label = label.clone();
                let stdout_reader =
                    thread::spawn(move || prefix_stream(stdout, &stdout_label, std::io::stdout()));
                let stderr_reader =
                    thread::spawn(move || prefix_stream(stderr, &stderr_label, std::io::stderr()));

                let status = child.wait();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();

                match status {
                    Ok(status) if status.success() => println!("[{}] done", label),
                    Ok(status) => {
                        return Err(Failure {
                            label,
                            lines: vec![],
                            code: status.code(),
                        })
                    }
                    Err(error) => {
                        return Err(Failure {
                            label,
                            lines: vec![format!("wait failed: {}", error)],
                            code: None,
                        })
                    }
                }
            }
            Ok(())
        }));
    }

    let mut first_failure: Option<Failure> = None;
    for handle in handles {
        if let Err(failure) = handle.join().unwrap() {
            if first_failure.is_none() {
                first_failure = Some(failure);
            }
        }
    }

    if let Some(failure) = first_failure {
        bail!("{} failed (exit {:?})", failure.label, failure.code);
    }
    Ok(())
}

fn spawn_build(cwd: &Path, env: &HashMap<String, String>) -> std::io::Result<std::process::Child> {
    let mut command = Command::new(cwd.join("build.sh"));
    command
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (name, value) in env {
        command.env(name, value);
    }
    command.spawn()
}

fn prefix_stream<R, W>(reader: R, label: &str, mut sink: W)
where
    R: std::io::Read + Send + 'static,
    W: Write + Send + 'static,
{
    for line in lossy_lines(BufReader::new(reader)) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        let _ = writeln!(sink, "[{}] {}", label, line);
        let _ = sink.flush();
    }
}

pub fn fmt_elapsed(elapsed: Duration) -> String {
    let seconds = elapsed.as_secs();
    if seconds >= 60 {
        format!("{}m{:02}s", seconds / 60, seconds % 60)
    } else {
        format!("{}s", seconds)
    }
}
