use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};

pub struct RunOpts<'a> {
    pub cwd: &'a Path,
    pub env: &'a HashMap<String, String>,
}

/// Spawn a subprocess with inherited stdio so output streams live. Exits
/// the current process with the child's exit code on failure.
pub fn run(argv: &[&str], opts: &RunOpts) -> Result<()> {
    let joined = argv.join(" ");
    println!(
        "{}{}",
        format!("→ {}", joined).cyan(),
        format!("  (cd {})", opts.cwd.display()).dimmed()
    );
    let status = Command::new(argv[0])
        .args(&argv[1..])
        .current_dir(opts.cwd)
        .envs(opts.env)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("failed to spawn {}", joined))?;
    if !status.success() {
        let code = status.code().unwrap_or(1);
        println!("{}", format!("✗ exited with {}", code).red());
        std::process::exit(code);
    }
    Ok(())
}

/// Run a subprocess and capture its stdout and stderr. Used for
/// the `mix run -e <snippet>` vehicle metadata probes. Returns the exit
/// code, stdout and stderr so the caller can decide how to report failures.
pub fn run_capture(
    argv: &[&str],
    cwd: &Path,
    env: &HashMap<String, String>,
) -> Result<(i32, String, String)> {
    let output = Command::new(argv[0])
        .args(&argv[1..])
        .current_dir(cwd)
        .envs(env)
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to spawn {}", argv[0]))?;
    let code = output.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    Ok((code, stdout, stderr))
}
