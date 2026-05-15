use anyhow::Result;

use crate::firmware;
use crate::resolve_args::resolve_vehicle_app;
use crate::shell;

pub fn run(vehicle: Option<String>, role: Option<String>) -> Result<()> {
    let args = resolve_vehicle_app(vehicle, role)?;
    let res = firmware::resolve(&args.vehicle, &args.application)?;
    let cwd = args.repo_root.join(&res.firmware_dir);
    shell::run(
        &["./build.sh"],
        &shell::RunOpts {
            cwd: &cwd,
            env: &res.env,
        },
    )
}
