use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

pub fn repo_root() -> Result<PathBuf> {
    if let Ok(env) = std::env::var("OVCS_ROOT") {
        return Ok(PathBuf::from(env));
    }
    let cwd = std::env::current_dir()?;
    find_root(&cwd)
}

fn find_root(dir: &Path) -> Result<PathBuf> {
    if dir.join("vehicles").is_dir() && dir.join("libraries").is_dir() {
        return Ok(dir.to_path_buf());
    }
    match dir.parent() {
        Some(parent) if parent != dir => find_root(parent),
        _ => bail!("Could not find OVCS repo root; set OVCS_ROOT or run from within the repo."),
    }
}
