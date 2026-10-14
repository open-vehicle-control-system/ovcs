//! The compute node's balena release for a vehicle: `compose/compute/`
//! plus the vehicle's Nav2 parameters, staged into one source root since
//! balena needs every build context inside the pushed directory.
//!
//! By default the release pulls the framework images CI publishes from
//! `main` when their sources change, and builds only the vehicle's Nav2
//! layer; `--build` stages the image sources instead.

use anyhow::{bail, Context, Result};
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::repo_root::repo_root;
use crate::resolve_args::resolve_vehicle;
use crate::ui;
use crate::vehicles::{self, Vehicle};

const REGISTRY: &str = "ghcr.io/open-vehicle-control-system/ovcs";

/// Keyfiles hold PSKs and are installed on the host by hand, never pushed.
const NOT_STAGED: &[&str] = &["host"];

/// The framework sources the published images are built from.
const IMAGE_SOURCES: &[&str] = &["compose/compute/images", "compose/compute/vehicle"];

/// Also republishes every image when it changes. Together with
/// IMAGE_SOURCES, the paths of the `images-changed` filter in
/// `.github/workflows/ros2.yml`.
const PUBLISHED_WITH: &str = ".github/workflows/ros2.yml";

pub enum Images {
    /// Pull the published images with this tag.
    Published(String),
    /// Build the images from this checkout's sources.
    Build,
}

pub fn images(tag: Option<String>, build: bool) -> Result<Images> {
    match (tag, build) {
        (_, true) => Ok(Images::Build),
        (Some(tag), false) => Ok(Images::Published(tag)),
        (None, false) => Ok(Images::Published(main_tag()?)),
    }
}

pub fn stage(vehicle: Option<String>, out: Option<String>, images: Images) -> Result<()> {
    let vehicle = resolve_vehicle(vehicle)?;
    let (destination, created) = match out {
        Some(out) => {
            let destination = PathBuf::from(out);
            if destination.exists() && fs::read_dir(&destination)?.next().is_some() {
                bail!("{} is not empty", destination.display());
            }
            (destination, false)
        }
        None => (private_staging_dir(&vehicle.dir)?, true),
    };
    let staged = stage_into(&vehicle, &destination, &images);
    if staged.is_err() && created {
        let _ = fs::remove_dir_all(&destination);
    }
    staged?;
    ui::sub_ok(&format!(
        "staged {} into {}",
        vehicle.dir,
        destination.display()
    ));
    Ok(())
}

/// A new staging directory only the user can open, so nobody else on the
/// machine can swap files in before `balena push` reads them.
fn private_staging_dir(vehicle_dir: &str) -> Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.subsec_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "ovcs-compute-{}-{}-{}",
        vehicle_dir,
        std::process::id(),
        nanos
    ));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .with_context(|| format!("creating the staging directory {}", dir.display()))?;
    Ok(dir)
}

/// `./ovcs compute push [<vehicle>] <target>`: a single argument that is
/// not a vehicle is the target, and the vehicle picker opens.
pub fn push(
    vehicle: Option<String>,
    target: Option<String>,
    images: Images,
    balena_args: Vec<String>,
) -> Result<()> {
    let (vehicle, target) = match (vehicle, target) {
        (Some(vehicle), Some(target)) => (resolve_vehicle(Some(vehicle))?, target),
        (Some(single), None) if !is_vehicle_dir(&single)? => (resolve_vehicle(None)?, single),
        _ => bail!("missing the push target: a balena fleet, or `<device>.local`"),
    };
    let staging_dir = private_staging_dir(&vehicle.dir)?;
    let staged = stage_into(&vehicle, &staging_dir, &images);
    if staged.is_err() {
        let _ = fs::remove_dir_all(&staging_dir);
    }
    staged?;

    ui::step(&format!(
        "balena push {} (source {})",
        target,
        staging_dir.display()
    ));
    let status = Command::new("balena")
        .arg("push")
        .arg(&target)
        .arg("--source")
        .arg(&staging_dir)
        .args(&balena_args)
        .status()
        .context("failed to spawn balena (run `mise install`)");
    let cleanup = fs::remove_dir_all(&staging_dir)
        .with_context(|| format!("removing the staging directory {}", staging_dir.display()));
    let status = status?;
    cleanup?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

fn is_vehicle_dir(name: &str) -> Result<bool> {
    Ok(vehicles::list(&repo_root()?)?
        .iter()
        .any(|vehicle| vehicle.dir == name))
}

/// `sha-<short>` of the last `main` commit, up to the one this checkout
/// is based on, that changed what CI publishes, provided this checkout's
/// image sources are still the same.
fn main_tag() -> Result<String> {
    let root = repo_root()?;
    let base = git(&root, &["merge-base", "HEAD", "origin/main"])
        .context("no merge base with origin/main; pass --tag or --build")?;
    let mut log = vec![
        "log",
        "-1",
        "--first-parent",
        "--format=%H",
        base.as_str(),
        "--",
    ];
    log.extend(IMAGE_SOURCES);
    log.push(PUBLISHED_WITH);
    let published = git(&root, &log)?;
    if published.is_empty() {
        bail!("no commit on origin/main published the images; pass --tag or --build");
    }
    let mut diff = vec!["diff", "--quiet", published.as_str(), "--"];
    diff.extend(IMAGE_SOURCES);
    let unchanged = Command::new("git")
        .args(&diff)
        .current_dir(&root)
        .status()
        .context("failed to spawn git")?
        .success();
    if !unchanged {
        bail!(
            "the image sources ({}) differ from the images published at {}, the latest your \
             origin/main knows of: `git fetch origin` if it is behind, or pass --build to build \
             them from this checkout",
            IMAGE_SOURCES.join(", "),
            &published[..7]
        );
    }
    Ok(format!("sha-{}", &published[..7]))
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(root)
        .stderr(Stdio::null())
        .output()
        .context("failed to spawn git")?;
    if !output.status.success() {
        bail!("git {} failed", args.join(" "));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn stage_into(vehicle: &Vehicle, destination: &Path, images: &Images) -> Result<()> {
    let root = repo_root()?;
    let compute = root.join("compose/compute");
    let nav2 = vehicle.path.join("nav2");
    if !nav2.join("nav2.yaml").is_file() {
        bail!(
            "{} has no nav2/nav2.yaml: the compute node runs Nav2 with the vehicle's parameters",
            vehicle.dir
        );
    }

    ui::step(&format!("Staging the compute node for {}", vehicle.dir));
    fs::create_dir_all(destination)?;
    match images {
        Images::Build => {
            for entry in fs::read_dir(&compute)? {
                let entry = entry?;
                if NOT_STAGED.iter().any(|name| entry.file_name() == *name) {
                    continue;
                }
                copy_tree(&entry.path(), &destination.join(entry.file_name()))?;
            }
            ui::sub("framework images built from this checkout");
        }
        Images::Published(tag) => {
            check_published(&format!("{REGISTRY}/nav2:{tag}"))?;
            let compose = fs::read_to_string(compute.join("docker-compose.yml"))?;
            fs::write(
                destination.join("docker-compose.yml"),
                published_compose(&compose, tag)?,
            )?;
            fs::copy(
                compute.join(".dockerignore"),
                destination.join(".dockerignore"),
            )?;
            fs::create_dir_all(destination.join("vehicle"))?;
            fs::write(
                destination.join("vehicle/Dockerfile"),
                format!("FROM {REGISTRY}/nav2:{tag}\nCOPY nav2 /opt/ovcs/config\n"),
            )?;
            ui::sub(&format!("framework images {REGISTRY}/*:{tag}"));
        }
    }
    copy_tree(&nav2, &destination.join("vehicle/nav2"))?;
    ui::sub(&format!(
        "Nav2 parameters from vehicles/{}/nav2",
        vehicle.dir
    ));
    Ok(())
}

/// The compute compose file with each framework `build:` replaced by its
/// published image, and Nav2 built from the vehicle's layer on top of it.
fn published_compose(compose: &str, tag: &str) -> Result<String> {
    let nav2 =
        Regex::new(r"(?m)^( +)build:\n +context: \.\n +dockerfile: images/nav2/Dockerfile\n")?;
    if !nav2.is_match(compose) {
        bail!("compose/compute/docker-compose.yml: the nav2 build block is not recognised");
    }
    let compose = nav2.replace(compose, "${1}build: ./vehicle\n");
    let image = Regex::new(r"(?m)^( +)build: \./images/([a-z0-9-]+)$")?;
    let compose = image.replace_all(&compose, format!("${{1}}image: {REGISTRY}/${{2}}:{tag}"));
    if compose
        .lines()
        .any(|line| line.trim_start().starts_with("build:") && line.trim() != "build: ./vehicle")
    {
        bail!("compose/compute/docker-compose.yml: a build: has no published image");
    }
    Ok(compose.into_owned())
}

/// A missing tag would only surface on balena's builders, minutes later.
fn check_published(reference: &str) -> Result<()> {
    match Command::new("docker")
        .args(["manifest", "inspect", reference])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => Ok(()),
        Ok(_) => bail!("{reference} is not published; pass --tag or --build"),
        Err(_) => {
            ui::sub_warn(&format!("docker not found: {reference} not checked"));
            Ok(())
        }
    }
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        }
    } else {
        fs::copy(from, to).with_context(|| format!("copying {}", from.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_compute_compose_file_maps_onto_published_images() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let compose = fs::read_to_string(root.join("compose/compute/docker-compose.yml")).unwrap();
        let published = published_compose(&compose, "sha-abc1234").unwrap();

        for name in [
            "wifi-firmware",
            "wifi-ap-radio",
            "bridge-no-nat",
            "ntp",
            "ros2",
        ] {
            assert!(published.contains(&format!("image: {REGISTRY}/{name}:sha-abc1234")));
        }
        assert!(published.contains("build: ./vehicle\n"));
        assert!(!published
            .lines()
            .any(|line| line.trim_start().starts_with("build: ./images")));
    }
}
