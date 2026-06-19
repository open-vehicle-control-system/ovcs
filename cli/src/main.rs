use anyhow::Result;
use clap::{Parser, Subcommand};

mod ansi;
mod build_runner;
mod commands;
mod firmware;
mod prompt;
mod repo_root;
mod resolve_args;
mod shell;
mod ui;
mod vehicles;

#[derive(Parser)]
#[command(
    name = "ovcs",
    version,
    about = "OVCS vehicle/firmware orchestrator",
    long_about = "Build, burn, upload, and inspect OVCS vehicle firmware."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

/// Most subcommands take a (vehicle, role) pair where:
/// - `vehicle` is the snake_case directory under `vehicles/` (e.g.
///   `ovcs1`, `ovcs_mini`, `obd2`).
/// - `role` is `vms`, `infotainment`, or any bridge firmware id declared
///   in the vehicle's `bridge_firmwares/0` callback.
///
/// Both positional args are **order-independent** — the resolver picks
/// the vehicle out of the two values and treats the other as the role.
/// Missing values prompt interactively when stdin is a tty; on a
/// non-tty, the command exits with status 2.
#[derive(Subcommand)]
enum Commands {
    /// List discovered vehicles and their Nerves targets
    Vehicles,
    /// Verify toolchain and vehicle packages
    Doctor,
    /// Build firmware for a (vehicle, role) pair
    Build {
        /// Build every role of the vehicle (vms, infotainment, each
        /// bridge). The role argument is ignored when set.
        #[arg(long)]
        all: bool,
        vehicle: Option<String>,
        role: Option<String>,
    },
    /// Burn firmware to an SD card for a (vehicle, role) pair
    Burn {
        /// Build the firmware first, then burn (one-shot for fresh edits)
        #[arg(long)]
        build: bool,
        vehicle: Option<String>,
        role: Option<String>,
    },
    /// Remove build artifacts for a (vehicle, role) pair
    Clean {
        vehicle: Option<String>,
        role: Option<String>,
    },
    /// OTA-upload firmware to a running device
    Upload {
        /// Build the firmware first, then upload (one-shot for fresh edits)
        #[arg(long)]
        build: bool,
        /// Target host (default: <vehicle>-<role>.local)
        #[arg(long)]
        host: Option<String>,
        /// Custom .fw file to push
        #[arg(short = 'f', long)]
        file: Option<String>,
        vehicle: Option<String>,
        role: Option<String>,
    },
    /// Host CAN helpers
    Can {
        #[command(subcommand)]
        action: CanAction,
    },
    /// Scaffold a new vehicle package from the bundled template
    New {
        /// New vehicle directory name (snake_case)
        name: String,
        /// Nerves target system for the VMS firmware
        #[arg(long, default_value = "ovcs_base_can_system_rpi4")]
        vms_target: String,
        /// Nerves target system for the infotainment firmware
        #[arg(long, default_value = "ovcs_base_can_system_rpi5")]
        infotainment_target: String,
        /// Scaffold a VMS-only vehicle (skip the infotainment side)
        #[arg(long)]
        no_infotainment: bool,
        /// Skip the bridge_firmware dep (omit `bridge_firmwares/0`)
        #[arg(long)]
        no_bridges: bool,
        /// Human-readable display name (e.g. "OVCS Mini").
        /// Defaults to the snake_case name title-cased on `_`.
        #[arg(long)]
        display_name: Option<String>,
    },
    /// Manage persistent SSH host keys per firmware role so device
    /// identities stay stable across burns (gitignored under
    /// vehicles/<dir>/priv/host_keys/)
    HostKeys {
        #[command(subcommand)]
        action: HostKeysAction,
    },
    /// Boot a vehicle locally — one BEAM per role
    #[command(long_about = "\
Provision vcan and spawn one BEAM per role (vms, infotainment, each \
bridge), all joined by OvcsBus.Cluster (Erlang distribution), \
mirroring the deployed topology. Attach with `./ovcs attach` from \
another terminal for logs + IEx.")]
    Run {
        vehicle: Option<String>,
        /// Don't auto-start firmware dev add-ons (dashboards, …); boot only the BEAMs.
        #[arg(long)]
        no_addons: bool,
    },
    /// Attach a split TUI to a running vehicle
    #[command(long_about = "\
Attach a split TUI (merged per-node logs + IEx shell) to a running \
vehicle — either the local dev BEAM or the N deployed Nerves devices.")]
    Attach { vehicle: Option<String> },
    /// Open an interactive IEx shell on a single deployed device over SSH
    #[command(long_about = "\
Open an interactive IEx shell on a single deployed device over SSH.

Targets the Nerves device's SSH-as-IEx login shell (requires the \
firmware to be flashed with `AUTHORIZED_SSH_KEYS`). For the multi-node \
split TUI with logs / bus / CAN panes, use `attach`.")]
    Connect {
        /// Override the target host (default: <vehicle>-<role>.local).
        /// Useful when mDNS isn't resolving and you know the device's IP.
        #[arg(long)]
        host: Option<String>,
        vehicle: Option<String>,
        role: Option<String>,
    },
}

#[derive(Subcommand)]
enum CanAction {
    /// Create + bring up the vcan interfaces a vehicle needs
    Setup { vehicle: Option<String> },
    /// Report which vcan interfaces a vehicle needs and whether they're up
    Status { vehicle: Option<String> },
}

#[derive(Subcommand)]
enum HostKeysAction {
    /// Generate any missing host keys for every firmware role
    Generate {
        /// Vehicle directory name (snake_case). Prompts if omitted.
        vehicle: Option<String>,
        /// Regenerate keys even if they already exist
        #[arg(long)]
        force: bool,
    },
    /// Check that every role has a complete set of host keys
    Verify {
        /// Vehicle directory name (snake_case). Prompts if omitted.
        vehicle: Option<String>,
    },
    /// Bundle a vehicle's host keys into a shareable archive
    Export {
        /// Vehicle directory name (snake_case). Prompts if omitted.
        vehicle: Option<String>,
        /// Output archive path (default: <vehicle>-host-keys.tar.gz)
        #[arg(short = 'o', long)]
        out: Option<String>,
    },
    /// Restore a vehicle's host keys from an exported archive
    Import {
        /// Vehicle directory name (snake_case). Prompts if omitted.
        vehicle: Option<String>,
        /// Archive produced by `host-keys export`
        #[arg(short = 'i', long = "from")]
        from: String,
        /// Overwrite existing keys instead of refusing
        #[arg(long)]
        force: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Vehicles => commands::vehicles::run(),
        Commands::Doctor => commands::doctor::run(),
        Commands::Build { all, vehicle, role } => commands::build::run(all, vehicle, role),
        Commands::Burn {
            build,
            vehicle,
            role,
        } => commands::burn::run(vehicle, role, build),
        Commands::Clean { vehicle, role } => commands::clean::run(vehicle, role),
        Commands::Upload {
            build,
            host,
            file,
            vehicle,
            role,
        } => commands::upload::run(vehicle, role, host, file, build),
        Commands::Can { action } => match action {
            CanAction::Setup { vehicle } => commands::can::setup(vehicle),
            CanAction::Status { vehicle } => commands::can::status(vehicle),
        },
        Commands::New {
            name,
            vms_target,
            infotainment_target,
            no_infotainment,
            no_bridges,
            display_name,
        } => commands::vehicle_new::run(
            name,
            vms_target,
            infotainment_target,
            no_infotainment,
            no_bridges,
            display_name,
        ),
        Commands::HostKeys { action } => match action {
            HostKeysAction::Generate { vehicle, force } => {
                commands::vehicle_host_keys::generate(vehicle, force)
            }
            HostKeysAction::Verify { vehicle } => commands::vehicle_host_keys::verify(vehicle),
            HostKeysAction::Export { vehicle, out } => {
                commands::vehicle_host_keys::export(vehicle, out)
            }
            HostKeysAction::Import {
                vehicle,
                from,
                force,
            } => commands::vehicle_host_keys::import(vehicle, from, force),
        },
        Commands::Run {
            vehicle,
            no_addons,
        } => commands::run::run(vehicle, no_addons),
        Commands::Attach { vehicle } => commands::attach::run(vehicle),
        Commands::Connect {
            host,
            vehicle,
            role,
        } => commands::connect::run(vehicle, role, host),
    }
}
