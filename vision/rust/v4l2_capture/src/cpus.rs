//! Keeps the program's threads off a heterogeneous processor's slowest
//! cores. A frame's conversion splits its rows evenly between threads and
//! waits for the last band, so a band on a slow core holds back the frame.

use std::io;
use std::path::Path;

const CPUS: &str = "/sys/devices/system/cpu";

/// The CPUs to run on of `capacities`, each CPU's number and the kernel's
/// `cpu_capacity` for it: all but the slowest, `None` when they are all as
/// fast or none is listed.
pub fn faster_than_slowest(capacities: &[(usize, u32)]) -> Option<Vec<usize>> {
    let slowest = capacities.iter().map(|&(_, capacity)| capacity).min()?;
    let faster: Vec<usize> = (capacities.iter())
        .filter(|&&(_, capacity)| capacity > slowest)
        .map(|&(cpu, _)| cpu)
        .collect();
    (!faster.is_empty()).then_some(faster)
}

/// Each CPU's number and capacity, in the CPUs' order, of the CPUs listed
/// under `cpus` (sysfs's `devices/system/cpu`) with one.
pub fn capacities(cpus: &Path) -> Vec<(usize, u32)> {
    let Ok(entries) = std::fs::read_dir(cpus) else {
        return Vec::new();
    };
    let mut capacities: Vec<(usize, u32)> = (entries.flatten())
        .filter_map(|entry| {
            let name = entry.file_name();
            let cpu = name.to_str()?.strip_prefix("cpu")?.parse().ok()?;
            let capacity = std::fs::read_to_string(entry.path().join("cpu_capacity")).ok()?;
            Some((cpu, capacity.trim().parse().ok()?))
        })
        .collect();
    capacities.sort_unstable();
    capacities
}

/// Restricts the calling thread, and the threads it starts from then on, to
/// the CPUs faster than the slowest; returns them, or `None` when every CPU
/// is as fast and the thread is left as it was.
pub fn avoid_slowest() -> io::Result<Option<Vec<usize>>> {
    let Some(cpus) = faster_than_slowest(&capacities(Path::new(CPUS))) else {
        return Ok(None);
    };
    // SAFETY: a zeroed cpu_set_t is an empty set; CPU_SET writes within it
    // for a CPU below CPU_SETSIZE.
    let set = unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        for &cpu in cpus.iter().filter(|&&cpu| cpu < libc::CPU_SETSIZE as usize) {
            libc::CPU_SET(cpu, &mut set);
        }
        set
    };
    // SAFETY: `set` is a valid cpu_set_t of the size given; 0 is the calling thread.
    if unsafe { libc::sched_setaffinity(0, std::mem::size_of_val(&set), &set) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(Some(cpus))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The Arduino VENTUNO Q's: two Cortex-A78 at 2.1 GHz, two at 2.4 GHz, four Cortex-A55.
    const VENTUNO_Q: [(usize, u32); 8] = [
        (0, 915),
        (1, 915),
        (2, 1024),
        (3, 1024),
        (4, 446),
        (5, 446),
        (6, 446),
        (7, 446),
    ];

    #[test]
    fn leaves_out_the_slowest_cpus() {
        assert_eq!(faster_than_slowest(&VENTUNO_Q), Some(vec![0, 1, 2, 3]));
    }

    #[test]
    fn leaves_out_only_the_slowest_of_three_kinds() {
        let three_kinds = [(0, 250), (1, 250), (2, 800), (3, 800), (4, 1024)];
        assert_eq!(faster_than_slowest(&three_kinds), Some(vec![2, 3, 4]));
    }

    #[test]
    fn keeps_every_cpu_when_they_are_as_fast() {
        let equal = [(0, 1024), (1, 1024), (2, 1024), (3, 1024)];
        assert_eq!(faster_than_slowest(&equal), None);
        assert_eq!(faster_than_slowest(&[]), None);
    }

    #[test]
    fn reads_each_cpus_capacity() {
        let cpus = std::env::temp_dir().join(format!("v4l2_capture_cpus_{}", std::process::id()));
        for (cpu, capacity) in [
            (0, Some("915\n")),
            (1, Some("446\n")),
            (10, Some("1024\n")),
            (2, None),
        ] {
            let dir = cpus.join(format!("cpu{cpu}"));
            std::fs::create_dir_all(&dir).unwrap();
            if let Some(capacity) = capacity {
                std::fs::write(dir.join("cpu_capacity"), capacity).unwrap();
            }
        }
        std::fs::create_dir_all(cpus.join("cpufreq")).unwrap();
        std::fs::write(cpus.join("online"), "0-10\n").unwrap();

        let read = capacities(&cpus);
        std::fs::remove_dir_all(&cpus).unwrap();
        assert_eq!(read, [(0, 915), (1, 446), (10, 1024)]);
    }

    #[test]
    fn reads_no_capacity_without_the_directory() {
        assert_eq!(capacities(Path::new("/nonexistent/cpu")), []);
    }
}
