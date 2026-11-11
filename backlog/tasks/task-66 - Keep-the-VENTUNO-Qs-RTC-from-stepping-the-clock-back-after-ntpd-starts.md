---
id: TASK-66
title: Keep the VENTUNO Q's RTC from stepping the clock back after ntpd starts
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 12:35'
labels:
  - ovcs
  - vision
dependencies: []
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's vision unit (Arduino VENTUNO Q) never synchronizes its clock after a boot. nerves_time starts BusyBox 1.38's `ntpd` about 4 s after boot; it holds no socket, sends no sync report, and the clock stays in 1970 for as long as it runs (over 40 minutes observed). Meanwhile eth0 is `:internet`, DNS resolves `pool.ntp.org`, and a one-shot `ntpd -n -w` from the unit gets replies at once. `NervesTime.restart_ntpd/0`, with the same server list, syncs in about 30 s. It happens on every boot, with or without `ZENOH_ENDPOINT_IP` in the server list.

`Ros2Zenoh.Client` publishes nothing until the clock is synchronized, so the unit's ROS 2 topics stay empty while its session shows connected.

The server list is also tied to the Zenoh router: the `vision`, `bridges` and `vms` firmwares' `config/target.exs` put `ZENOH_ENDPOINT_IP` first in `:nerves_time, :servers`. A vehicle without a compute node, such as OVCS1, or a router running on a development machine, puts a host that serves no time first in the list: TASK-68 separates the two.

Root cause: the kernel steps the clock back after `ntpd` has started. The VENTUNO Q system builds the PMIC RTC driver as a module (`CONFIG_RTC_DRV_PM8XXX=m`) with `CONFIG_RTC_HCTOSYS=y`; it registers about 6.5 s after boot (`rtc-pm8xxx ...: setting system clock to 1970-01-01T04:08:40 UTC`), after `ntpd` started at about 4 s. BusyBox `ntpd` schedules on the wall clock (`poll()` sleeps `next_action_time - cur_time`), so a step back of decades makes it sleep for decades. The RTC counts from the PMIC's power-up and keeps 1970 after NTP has set the clock (`CONFIG_RTC_SYSTOHC=y` does not stick), so it never holds real time. BusyBox does retry name resolution and failed sends (`HOSTNAME_INTERVAL`, `RETRY_INTERVAL`), so a start without network alone recovers. nerves_time sets the clock forward before the step: its first log line is stamped 2026-11-05, and the RTC sets 1970 about 2 s later.

Options:

- In `nerves_system_arduino_ventuno_q`, disable `CONFIG_RTC_HCTOSYS` (and `CONFIG_RTC_SYSTOHC`): the kernel never sets the clock from an RTC that cannot hold the time, and nerves_time's sane time and NTP own it.
- Build `rtc-pm8xxx` into the kernel so it registers before userspace: depends on probe order (SPMI), and still sets 1970 at every boot.
- Restart `ntpd` when the network is up and the clock is not synchronized: in OVCS, no system rebuild; works when the restart comes after the RTC step.

Chosen: the last, as `OvcsVehicle.ClockSync`, a target-only child of the vision, bridges and VMS firmwares. It checks when VintageNet's global connection becomes `:internet` and every 2 minutes after its last check; a check restarts `ntpd` (`NervesTime.restart_ntpd/0`) when the connection is `:internet` and `NervesTime.synchronized?/0` is false. The periodic check covers a network that is up before the RTC step; 2 minutes leaves a first sync, about 30 s here, time to finish. Disabling `CONFIG_RTC_HCTOSYS` in the system stays a follow-up: the step back still affects log timestamps and the clock checks in its first seconds.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The root cause of the boot-time `ntpd` not syncing is identified and recorded here
- [x] #2 A board booted before its network is up synchronizes its clock within a minute of the network coming up, without a manual restart
- [ ] #3 OVCS1's vision unit publishes its ROS 2 topics after a cold boot
- [x] #4 `OvcsVehicle.ClockSync` is covered by tests and started on target by the vision, bridges and VMS firmwares
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
On OVCS1's vision unit, after a firmware update reboot: the RTC set 1970 at 6.79 s, eth0's link came up at 7.47 s, `ClockSync` restarted `ntpd` once the connection was `:internet` (about 14 s), and the clock was synchronized by 71 s; ROS 2 topics flowed with no manual step. Without `ClockSync`, four boots in a row stayed unsynchronized. Not yet checked: a cold boot (power cycle) with `ClockSync`.
<!-- SECTION:NOTES:END -->
