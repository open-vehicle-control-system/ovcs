use anyhow::Result;
use owo_colors::OwoColorize;

use crate::repo_root::repo_root;
use crate::ui::step;
use crate::vehicles::{self, bridge_firmwares, nerves_target};

pub fn run() -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    step("Discovered vehicles:");
    println!();
    for v in &list {
        println!("  {}  ({})", v.dir.cyan(), v.module);
        let vms = nerves_target(v, "vms")?.unwrap_or_else(|| "—".to_string());
        let info = nerves_target(v, "infotainment")?.unwrap_or_else(|| "—".to_string());
        println!("    vms          → {}", vms);
        println!("    infotainment → {}", info);

        let bridges = bridge_firmwares(v).unwrap_or_default();
        if !bridges.is_empty() {
            let mut entries: Vec<(String, String)> = bridges
                .into_iter()
                .map(|(id, fw)| (id, fw.target))
                .collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            println!("    bridges");
            for (id, target) in entries {
                println!("      {}  → {}", id.cyan(), target);
            }
        }

        println!();
    }
    Ok(())
}
