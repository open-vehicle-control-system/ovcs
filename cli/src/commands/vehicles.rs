use anyhow::Result;
use owo_colors::OwoColorize;

use crate::repo_root::repo_root;
use crate::vehicles::{self, nerves_target};

pub fn run() -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    println!("{}", "Discovered vehicles:".bold());
    println!();
    for v in &list {
        println!("  {}  ({})", v.dir.cyan(), v.module);
        let vms = nerves_target(v, "vms")?.unwrap_or_else(|| "—".to_string());
        let info = nerves_target(v, "infotainment")?.unwrap_or_else(|| "—".to_string());
        println!("    vms          → {}", vms);
        println!("    infotainment → {}", info);
        println!();
    }
    Ok(())
}
