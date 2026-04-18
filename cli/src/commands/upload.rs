use anyhow::Result;

use crate::firmware;
use crate::resolve_args::resolve_vehicle_app;
use crate::shell;
use crate::vehicles;

pub fn run(
    first: Option<String>,
    second: Option<String>,
    host: Option<String>,
    file: Option<String>,
) -> Result<()> {
    let args = resolve_vehicle_app(first, second)?;
    let res = firmware::resolve(&args.vehicle, &args.application)?;
    let cwd = args.repo_root.join(&res.firmware_dir);

    let host = host.unwrap_or_else(|| vehicles::host_for(&args.vehicle.dir, &args.application));
    let mut argv: Vec<&str> = vec!["./upload.sh", &host];
    if let Some(ref f) = file {
        argv.push(f);
    }
    shell::run(
        &argv,
        &shell::RunOpts {
            cwd: &cwd,
            env: &res.env,
        },
    )
}
