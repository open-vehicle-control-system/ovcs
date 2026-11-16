//! The times of an execution: QNN's basic profile, read after it, and the wall time around it.

use std::ops::Range;
use std::ptr;

use crate::ffi::*;
use crate::stage_times::{Stage, StageTimes};
use crate::{check, missing};

/// The accelerator's time, by order of preference: the graph's execution on the HTP
/// without, then with, its wait for the HTP's resources, which another graph may hold.
const ACCELERATOR_EVENTS: [QnnProfile_EventType_t; 2] = [
    QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_EXCL_WAIT_TIME_MICROSEC,
    QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_TIME_MICROSEC,
];

/// Executions a profile handle records before it is replaced, which bounds its
/// events should it keep every execution's.
pub(crate) const EXECUTIONS_PER_PROFILE: usize = 16;

/// What an execution's time measures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeSource {
    /// The HTP's execution time, from QNN's profile.
    Accelerator,
    /// The wall time around `graphExecute`.
    WallTime,
}

/// An execution's time in µs and what it measures, and where the time around it went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timing {
    pub micros: u64,
    pub source: TimeSource,
    /// The wall time around `graphExecute`.
    pub graph_execute_micros: u64,
    /// Reading the execution's events off the profile, after `graphExecute`.
    pub profile_read_micros: u64,
    pub profiled: ProfiledTimes,
}

/// The stages `Timing::add_to` adds: `graphExecute`'s wall time, QNN's times inside it, then
/// the profile's reading after it.
pub const EXECUTION_STAGES: [&str; 6] = [
    "graphExecute",
    "QNN execute",
    "host RPC",
    "HTP RPC",
    "HTP",
    "profile read",
];

impl Timing {
    /// Adds the execution's times to `times`, whose `stages` are `EXECUTION_STAGES`.
    pub fn add_to(&self, times: &mut StageTimes, stages: &[Stage; 6]) {
        let [graph_execute, execute, host_rpc, htp_rpc, htp, profile_read] = *stages;
        times.add(graph_execute, self.graph_execute_micros);
        for (stage, micros) in [
            (execute, self.profiled.execute_micros),
            (host_rpc, self.profiled.host_rpc_micros),
            (htp_rpc, self.profiled.htp_rpc_micros),
            (htp, self.profiled.accelerator_micros),
        ] {
            if let Some(micros) = micros {
                times.add(stage, micros);
            }
        }
        times.add(profile_read, self.profile_read_micros);
    }
}

/// QNN's own times of an execution in µs, from its profile, when it reports them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProfiledTimes {
    /// `graphExecute` as QNN times it.
    pub execute_micros: Option<u64>,
    /// The remote procedure call, as the CPU times it.
    pub host_rpc_micros: Option<u64>,
    /// The remote procedure call, as the HTP times it.
    pub htp_rpc_micros: Option<u64>,
    /// The graph's execution on the HTP (`ACCELERATOR_EVENTS`).
    pub accelerator_micros: Option<u64>,
}

impl ProfiledTimes {
    pub(crate) fn of(events: &[ProfileEvent]) -> ProfiledTimes {
        ProfiledTimes {
            execute_micros: latest_micros(events, QNN_PROFILE_EVENTTYPE_EXECUTE),
            host_rpc_micros: latest_micros(
                events,
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_HOST_RPC_TIME_MICROSEC,
            ),
            htp_rpc_micros: latest_micros(
                events,
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_HTP_RPC_TIME_MICROSEC,
            ),
            accelerator_micros: accelerator_micros(events),
        }
    }
}

/// One profile event's type, unit and value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ProfileEvent {
    pub(crate) kind: QnnProfile_EventType_t,
    pub(crate) unit: QnnProfile_EventUnit_t,
    pub(crate) value: QnnProfile_EventValue_t,
}

/// The accelerator's time in µs among one execution's events: the latest of the
/// most preferred kind reported (`ACCELERATOR_EVENTS`).
fn accelerator_micros(events: &[ProfileEvent]) -> Option<u64> {
    ACCELERATOR_EVENTS
        .iter()
        .find_map(|&kind| latest_micros(events, kind))
}

/// The latest event of `kind` among one execution's events, in µs.
fn latest_micros(events: &[ProfileEvent], kind: QnnProfile_EventType_t) -> Option<u64> {
    events
        .iter()
        .rev()
        .find(|event| event.kind == kind && event.unit == QNN_PROFILE_EVENTUNIT_MICROSEC)
        .map(|event| event.value)
}

/// Which of a profile handle's top-level events the latest execution stored. A
/// handle keeps either only the latest execution's events or every one's, up to
/// a backend-specific maximum; its second execution tells which.
#[derive(Debug, Default)]
pub(crate) struct EventCursor {
    /// Executions since the handle was created.
    pub(crate) executions: usize,
    previous_total: usize,
    keeps_every_execution: bool,
}

impl EventCursor {
    /// The latest execution's top-level events among the handle's `total`; `None`
    /// when a handle that keeps every execution's events stored none for it.
    pub(crate) fn latest_execution(&mut self, total: usize) -> Option<Range<usize>> {
        self.executions += 1;
        let previous = std::mem::replace(&mut self.previous_total, total);
        if self.executions == 2 {
            self.keeps_every_execution = total > previous;
        }
        match (self.executions, self.keeps_every_execution) {
            (1, _) | (_, false) => Some(0..total),
            (_, true) if total > previous => Some(previous..total),
            (_, true) => None,
        }
    }
}

/// A basic-level profile handle passed to every execution.
pub(crate) struct Profile {
    pub(crate) handle: Qnn_ProfileHandle_t,
    pub(crate) cursor: EventCursor,
}

/// A basic-level profile handle on `backend`.
pub(crate) fn create_profile(
    interface: &QnnInterface_ImplementationV2_39_t,
    backend: Qnn_BackendHandle_t,
) -> Result<Qnn_ProfileHandle_t, String> {
    let profile_create = interface
        .profileCreate
        .ok_or_else(|| missing("profileCreate"))?;
    let mut handle: Qnn_ProfileHandle_t = ptr::null_mut();
    // SAFETY: `backend` is the session's live backend, and QNN writes only the handle.
    check("profileCreate", unsafe {
        profile_create(backend, QNN_PROFILE_LEVEL_BASIC, &mut handle)
    })?;
    Ok(handle)
}

/// The profile's top-level events into `ids`, in place of its contents; none when they cannot
/// be read.
///
/// # Safety
/// `profile` is a live handle of `interface`'s library.
pub(crate) unsafe fn top_level_events(
    interface: &QnnInterface_ImplementationV2_39_t,
    profile: Qnn_ProfileHandle_t,
    ids: &mut Vec<QnnProfile_EventId_t>,
) {
    ids.clear();
    let Some(get_events) = interface.profileGetEvents else {
        return;
    };
    let mut returned: *const QnnProfile_EventId_t = ptr::null();
    let mut count = 0u32;
    if get_events(profile, &mut returned, &mut count) != 0 || returned.is_null() {
        return;
    }
    ids.extend_from_slice(std::slice::from_raw_parts(returned, count as usize));
}

/// `id`'s data, then its sub-events', depth first; an event whose data cannot be
/// read is skipped.
///
/// # Safety
/// `id` is an event of a profile handle still alive.
pub(crate) unsafe fn collect_events(
    interface: &QnnInterface_ImplementationV2_39_t,
    id: QnnProfile_EventId_t,
    events: &mut Vec<ProfileEvent>,
) {
    if let Some(get_event_data) = interface.profileGetEventData {
        let mut data = QnnProfile_EventData_t {
            type_: 0,
            unit: 0,
            value: 0,
            identifier: ptr::null(),
        };
        if get_event_data(id, &mut data) == 0 {
            events.push(ProfileEvent {
                kind: data.type_,
                unit: data.unit,
                value: data.value,
            });
        }
    }
    let Some(get_sub_events) = interface.profileGetSubEvents else {
        return;
    };
    let mut ids: *const QnnProfile_EventId_t = ptr::null();
    let mut count = 0u32;
    if get_sub_events(id, &mut ids, &mut count) != 0 || ids.is_null() {
        return;
    }
    for &sub_event in std::slice::from_raw_parts(ids, count as usize) {
        collect_events(interface, sub_event, events);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;
    use crate::STAGE_TIMES_EVERY;

    fn event(kind: u32, unit: u32, value: u64) -> ProfileEvent {
        ProfileEvent { kind, unit, value }
    }

    const EXCLUDING_WAIT: u32 =
        QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_EXCL_WAIT_TIME_MICROSEC;

    const INCLUDING_WAIT: u32 = QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_TIME_MICROSEC;

    const MICROSECONDS: u32 = QNN_PROFILE_EVENTUNIT_MICROSEC;

    #[test]
    fn accelerator_time_excludes_the_wait_when_reported() {
        let events = [
            event(QNN_PROFILE_EVENTTYPE_EXECUTE, MICROSECONDS, 3304),
            event(
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_HOST_RPC_TIME_MICROSEC,
                MICROSECONDS,
                2932,
            ),
            event(
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_TIME_CYCLE,
                QNN_PROFILE_EVENTUNIT_CYCLES,
                9_000_000,
            ),
            event(EXCLUDING_WAIT, MICROSECONDS, 2556),
            event(INCLUDING_WAIT, MICROSECONDS, 2593),
        ];
        assert_eq!(accelerator_micros(&events), Some(2556));
    }

    #[test]
    fn profiled_times_are_the_execute_rpc_and_accelerator_events() {
        let events = [
            event(QNN_PROFILE_EVENTTYPE_EXECUTE, MICROSECONDS, 3304),
            event(
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_HOST_RPC_TIME_MICROSEC,
                MICROSECONDS,
                2932,
            ),
            event(
                QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_HTP_RPC_TIME_MICROSEC,
                MICROSECONDS,
                2650,
            ),
            event(INCLUDING_WAIT, MICROSECONDS, 2593),
        ];
        assert_eq!(
            ProfiledTimes::of(&events),
            ProfiledTimes {
                execute_micros: Some(3304),
                host_rpc_micros: Some(2932),
                htp_rpc_micros: Some(2650),
                accelerator_micros: Some(2593),
            }
        );
        assert_eq!(ProfiledTimes::of(&[]), ProfiledTimes::default());
    }

    #[test]
    fn an_execution_adds_the_times_its_profile_reported() {
        let start = Instant::now();
        let (mut times, stages) = StageTimes::new(EXECUTION_STAGES, STAGE_TIMES_EVERY, start);
        let timing = Timing {
            micros: 8700,
            source: TimeSource::Accelerator,
            graph_execute_micros: 20_000,
            profile_read_micros: 300,
            profiled: ProfiledTimes {
                execute_micros: Some(12_000),
                host_rpc_micros: Some(9000),
                htp_rpc_micros: None,
                accelerator_micros: Some(8700),
            },
        };
        timing.add_to(&mut times, &stages);
        times.count_request();
        assert_eq!(
            times.line(start + STAGE_TIMES_EVERY).as_deref(),
            Some(
                "last 60 s: 1 requests, us each: graphExecute 20000, QNN execute 12000, \
                 host RPC 9000, HTP RPC none, HTP 8700, profile read 300"
            )
        );
    }

    #[test]
    fn accelerator_time_includes_the_wait_otherwise() {
        let events = [
            event(QNN_PROFILE_EVENTTYPE_EXECUTE, MICROSECONDS, 3304),
            event(INCLUDING_WAIT, MICROSECONDS, 2593),
        ];
        assert_eq!(accelerator_micros(&events), Some(2593));
    }

    #[test]
    fn accelerator_time_takes_the_latest_event() {
        let events = [
            event(EXCLUDING_WAIT, MICROSECONDS, 2556),
            event(EXCLUDING_WAIT, MICROSECONDS, 2601),
        ];
        assert_eq!(accelerator_micros(&events), Some(2601));
    }

    #[test]
    fn accelerator_time_needs_microseconds() {
        let events = [
            event(EXCLUDING_WAIT, QNN_PROFILE_EVENTUNIT_CYCLES, 9_000_000),
            event(INCLUDING_WAIT, MICROSECONDS, 2593),
        ];
        assert_eq!(accelerator_micros(&events), Some(2593));
        assert_eq!(
            accelerator_micros(&[event(INCLUDING_WAIT, QNN_PROFILE_EVENTUNIT_COUNT, 1)]),
            None
        );
    }

    #[test]
    fn no_accelerator_time_without_its_events() {
        assert_eq!(accelerator_micros(&[]), None);
        let events = [event(QNN_PROFILE_EVENTTYPE_EXECUTE, MICROSECONDS, 3304)];
        assert_eq!(accelerator_micros(&events), None);
    }

    /// The cursor's answer after each execution, given the handle's top-level totals.
    fn latest_executions(totals: &[usize]) -> Vec<Option<std::ops::Range<usize>>> {
        let mut cursor = EventCursor::default();
        totals
            .iter()
            .map(|&total| cursor.latest_execution(total))
            .collect()
    }

    #[test]
    fn an_accumulating_handle_gives_the_events_added_by_each_execution() {
        assert_eq!(
            latest_executions(&[3, 6, 9]),
            [Some(0..3), Some(3..6), Some(6..9)]
        );
    }

    #[test]
    fn an_execution_adding_more_events_keeps_them_all() {
        assert_eq!(
            latest_executions(&[3, 6, 10]),
            [Some(0..3), Some(3..6), Some(6..10)]
        );
    }

    #[test]
    fn a_capped_handle_gives_nothing_once_it_stops_growing() {
        assert_eq!(
            latest_executions(&[3, 6, 7, 7, 7]),
            [Some(0..3), Some(3..6), Some(6..7), None, None]
        );
    }

    #[test]
    fn a_resetting_handle_gives_all_its_events() {
        assert_eq!(
            latest_executions(&[3, 3, 3, 4, 2]),
            [Some(0..3), Some(0..3), Some(0..3), Some(0..4), Some(0..2)]
        );
    }

    #[test]
    fn the_cursor_counts_executions() {
        let mut cursor = EventCursor::default();
        for total in [3, 6, 6] {
            cursor.latest_execution(total);
        }
        assert_eq!(cursor.executions, 3);
    }
}
