use anyhow::Result;

use crate::firmware;
use crate::resolve_args::resolve_vehicle_app;
use crate::shell;

pub fn run(first: Option<String>, second: Option<String>, build: bool) -> Result<()> {
    let args = resolve_vehicle_app(first, second)?;
    let res = firmware::resolve(&args.vehicle, &args.application)?;
    let cwd = args.repo_root.join(&res.firmware_dir);
    let opts = shell::RunOpts {
        cwd: &cwd,
        env: &res.env,
    };

    if build {
        shell::run(&["./build.sh"], &opts)?;
    }
    shell::run(&["./burn.sh"], &opts)
}
