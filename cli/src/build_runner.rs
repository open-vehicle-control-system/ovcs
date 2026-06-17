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
//! On a TTY every step's `panes` render as live spinner lines
//! (buildkit-style) showing the build's latest log line; queued steps read
//! `queued…` until their turn. On failure the offending step's full
//! buffered output is dumped and later steps in that lane are skipped.
//! Off a TTY (CI, pipes) we fall back to line-prefixed `[<label>] …`
//! interleaved output so logs stay greppable.
//!
//! A failing lane doesn't abort its siblings — every lane runs to
//! completion so the user sees all failures, and the first failure's log
//! is surfaced at the end.

use anyhow::{bail, Result};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::ansi::{is_blank_after_ansi, strip_ansi};

/// One `build.sh` invocation in a lane's directory, with its env.
///
/// `panes` are the labels shown as separate progress lines that all track
/// this single process — usually one label, but `run`'s host warm-up
/// shares one `bridges/firmware` build across several bridge roles.
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
    let mp = MultiProgress::new();
    let tag_width = lanes
        .iter()
        .flat_map(|l| l.steps.iter())
        .flat_map(|s| s.panes.iter())
        .map(|p| p.len())
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
                        let bar = mp.add(ProgressBar::new_spinner());
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

    let mut first_err: Option<Failure> = None;
    for h in handles {
        if let Err(e) = h.join().unwrap() {
            if first_err.is_none() {
                first_err = Some(e);
            }
        }
    }

    // Drop MultiProgress before any eprintln! so its terminal state isn't
    // tangled with the dumped log.
    drop(mp);

    if let Some(f) = first_err {
        eprintln!();
        eprintln!("{}", format!("── {} log ──", f.label).red().bold());
        for line in &f.lines {
            eprintln!("{}", line);
        }
        bail!("{} failed (exit {:?})", f.label, f.code);
    }

    Ok(())
}

fn run_lane_panes(
    cwd: &Path,
    steps: Vec<BuildStep>,
    step_bars: Vec<Vec<ProgressBar>>,
) -> Result<(), Failure> {
    for (i, step) in steps.into_iter().enumerate() {
        let bars = &step_bars[i];
        for bar in bars {
            bar.set_message("starting…".to_string());
            bar.enable_steady_tick(Duration::from_millis(100));
        }
        if let Err(f) = run_step_panes(cwd, &step.env, bars) {
            // Skip the rest of this lane — they depend on the shared dir
            // the failed step left in an unknown state.
            for later in &step_bars[i + 1..] {
                for bar in later {
                    bar.finish_with_message("skipped".dimmed().to_string());
                }
            }
            return Err(f);
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
        .map(|b| b.prefix().trim_end().to_string())
        .collect::<Vec<_>>()
        .join("+");
    let buf: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let start = Instant::now();
    let finish_all = |msg: String| {
        for bar in bars {
            bar.finish_with_message(msg.clone());
        }
    };

    let mut child = match spawn_build(cwd, env) {
        Ok(c) => c,
        Err(e) => {
            let msg = format!("spawn failed: {}", e);
            finish_all(msg.clone().red().to_string());
            return Err(Failure {
                label,
                lines: vec![msg],
                code: None,
            });
        }
    };

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let bars_arc: Arc<Vec<ProgressBar>> = Arc::new(bars.to_vec());
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
    let elapsed = fmt_elapsed(start.elapsed());
    match status {
        Ok(s) if s.success() => {
            finish_all(format!("done ({})", elapsed).green().to_string());
            Ok(())
        }
        Ok(s) => {
            finish_all(
                format!("FAILED (exit {}, {})", s.code().unwrap_or(-1), elapsed)
                    .red()
                    .to_string(),
            );
            Err(Failure {
                label,
                lines,
                code: s.code(),
            })
        }
        Err(e) => {
            finish_all(format!("wait failed: {}", e).red().to_string());
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
fn capture_stream<R>(reader: R, bars: &[ProgressBar], buf: &Arc<Mutex<Vec<String>>>)
where
    R: std::io::Read + Send + 'static,
{
    for line in BufReader::new(reader).lines().map_while(|l| l.ok()) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        let display = strip_ansi(&line).trim_start().to_string();
        for bar in bars {
            bar.set_message(display.clone());
        }
        buf.lock().unwrap().push(line);
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
                    Ok(c) => c,
                    Err(e) => {
                        return Err(Failure {
                            label,
                            lines: vec![format!("spawn failed: {}", e)],
                            code: None,
                        })
                    }
                };

                let stdout = child.stdout.take().unwrap();
                let stderr = child.stderr.take().unwrap();
                let l1 = label.clone();
                let l2 = label.clone();
                let t1 = thread::spawn(move || prefix_stream(stdout, &l1, std::io::stdout()));
                let t2 = thread::spawn(move || prefix_stream(stderr, &l2, std::io::stderr()));

                let status = child.wait();
                let _ = t1.join();
                let _ = t2.join();

                match status {
                    Ok(s) if s.success() => println!("[{}] done", label),
                    Ok(s) => {
                        return Err(Failure {
                            label,
                            lines: vec![],
                            code: s.code(),
                        })
                    }
                    Err(e) => {
                        return Err(Failure {
                            label,
                            lines: vec![format!("wait failed: {}", e)],
                            code: None,
                        })
                    }
                }
            }
            Ok(())
        }));
    }

    let mut first_err: Option<Failure> = None;
    for h in handles {
        if let Err(e) = h.join().unwrap() {
            if first_err.is_none() {
                first_err = Some(e);
            }
        }
    }

    if let Some(f) = first_err {
        bail!("{} failed (exit {:?})", f.label, f.code);
    }
    Ok(())
}

fn spawn_build(cwd: &Path, env: &HashMap<String, String>) -> std::io::Result<std::process::Child> {
    let mut cmd = Command::new(cwd.join("build.sh"));
    cmd.current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.spawn()
}

fn prefix_stream<R, W>(reader: R, label: &str, mut sink: W)
where
    R: std::io::Read + Send + 'static,
    W: Write + Send + 'static,
{
    for line in BufReader::new(reader).lines().map_while(|l| l.ok()) {
        if is_blank_after_ansi(&line) {
            continue;
        }
        let _ = writeln!(sink, "[{}] {}", label, line);
        let _ = sink.flush();
    }
}

pub fn fmt_elapsed(d: Duration) -> String {
    let secs = d.as_secs();
    if secs >= 60 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}s", secs)
    }
}
