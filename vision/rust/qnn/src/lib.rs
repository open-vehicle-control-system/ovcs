//! A QNN context binary run on the HTP backend, through QAIRT's shared
//! libraries loaded at run time from the library path. Each execution is timed
//! by QNN's basic profiling, the HTP's own execution time, or by the wall time
//! around `graphExecute` when the profile is unavailable; `TimeLog` says which.

#[allow(
    non_upper_case_globals,
    non_camel_case_types,
    non_snake_case,
    dead_code,
    clippy::all
)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/qnn.rs"));
}

mod time_log;

pub use time_log::TimeLog;

use std::ffi::{c_void, CStr};
use std::ops::Range;
use std::ptr;
use std::time::Instant;

use ffi::*;
use libloading::Library;

type GetProviders =
    unsafe extern "C" fn(*mut *mut *const QnnInterface_t, *mut u32) -> Qnn_ErrorHandle_t;
type GetSystemProviders =
    unsafe extern "C" fn(*mut *mut *const QnnSystemInterface_t, *mut u32) -> Qnn_ErrorHandle_t;

/// A graph input or output: its name, shape, 8-bit quantisation if any, and size.
pub struct Tensor {
    pub name: String,
    pub dimensions: Vec<u32>,
    /// `(scale, offset)`: a value `q` stands for `(q + offset) × scale`.
    pub scale_offset: Option<(f32, i32)>,
    /// Whether an element is one unsigned byte, quantised or not.
    pub unsigned_8bit: bool,
    pub bytes: usize,
    raw: Qnn_Tensor_t,
}

/// The accelerator's time, by order of preference: the graph's execution on the HTP
/// without, then with, its wait for the HTP's resources, which another graph may hold.
const ACCELERATOR_EVENTS: [QnnProfile_EventType_t; 2] = [
    QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_EXCL_WAIT_TIME_MICROSEC,
    QNN_HTP_PROFILE_EVENTTYPE_GRAPH_EXECUTE_ACCEL_TIME_MICROSEC,
];

/// Executions a profile handle records before it is replaced, which bounds its
/// events should it keep every execution's.
const EXECUTIONS_PER_PROFILE: usize = 16;

/// What an execution's time measures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeSource {
    /// The HTP's execution time, from QNN's profile.
    Accelerator,
    /// The wall time around `graphExecute`.
    WallTime,
}

/// An execution's time in µs and what it measures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timing {
    pub micros: u64,
    pub source: TimeSource,
}

/// One profile event's type, unit and value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ProfileEvent {
    kind: QnnProfile_EventType_t,
    unit: QnnProfile_EventUnit_t,
    value: QnnProfile_EventValue_t,
}

/// The accelerator's time in µs among one execution's events: the latest of the
/// most preferred kind reported (`ACCELERATOR_EVENTS`).
fn accelerator_micros(events: &[ProfileEvent]) -> Option<u64> {
    ACCELERATOR_EVENTS.iter().find_map(|&kind| {
        events
            .iter()
            .rev()
            .find(|event| event.kind == kind && event.unit == QNN_PROFILE_EVENTUNIT_MICROSEC)
            .map(|event| event.value)
    })
}

/// Which of a profile handle's top-level events the latest execution stored. A
/// handle keeps either only the latest execution's events or every one's, up to
/// a backend-specific maximum; its second execution tells which.
#[derive(Debug, Default)]
struct EventCursor {
    /// Executions since the handle was created.
    executions: usize,
    previous_total: usize,
    keeps_every_execution: bool,
}

impl EventCursor {
    /// The latest execution's top-level events among the handle's `total`; `None`
    /// when a handle that keeps every execution's events stored none for it.
    fn latest_execution(&mut self, total: usize) -> Option<Range<usize>> {
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
struct Profile {
    handle: Qnn_ProfileHandle_t,
    cursor: EventCursor,
}

/// A context binary's first graph, ready to execute.
pub struct Model {
    interface: QnnInterface_ImplementationV2_39_t,
    graph: Qnn_GraphHandle_t,
    pub inputs: Vec<Tensor>,
    pub outputs: Vec<Tensor>,
    profile: Option<Profile>,
    /// Why executions are timed by the wall time, once the profile is unavailable.
    pub profile_error: Option<String>,
    /// The first profiled execution's events, until `take_profile_report`.
    profile_report: Option<String>,
    profile_reported: bool,
    backend: Qnn_BackendHandle_t,
    // The context and the libraries live as long as the process.
    _context: Qnn_ContextHandle_t,
    _libraries: [Library; 2],
}

fn check(what: &str, status: Qnn_ErrorHandle_t) -> Result<(), String> {
    if status == 0 {
        Ok(())
    } else {
        Err(format!("{what} failed with QNN error {status}"))
    }
}

fn missing(what: &str) -> String {
    format!("the QNN library has no {what}")
}

fn is_unsigned_8bit(data_type: Qnn_DataType_t) -> bool {
    data_type == QNN_DATATYPE_UFIXED_POINT_8 || data_type == QNN_DATATYPE_UINT_8
}

/// The bytes one element of `data_type` takes: QNN encodes its bit width
/// in the low byte, written as decimal digits (0x08, 0x16, 0x32, 0x64).
fn element_bytes(data_type: Qnn_DataType_t) -> Option<usize> {
    match data_type & 0xff {
        0x08 => Some(1),
        0x16 => Some(2),
        0x32 => Some(4),
        0x64 => Some(8),
        _ => None,
    }
}

/// The tensor's version 1 fields, which version 2 begins with.
unsafe fn fields(tensor: &Qnn_Tensor_t) -> &Qnn_TensorV1_t {
    &tensor.__bindgen_anon_1.v1
}

unsafe fn describe(raw: &Qnn_Tensor_t) -> Result<Tensor, String> {
    if raw.version != QNN_TENSOR_VERSION_1 && raw.version != QNN_TENSOR_VERSION_2 {
        return Err(format!("unknown tensor version {}", raw.version));
    }
    let v1 = fields(raw);
    let name = if v1.name.is_null() {
        String::new()
    } else {
        CStr::from_ptr(v1.name).to_string_lossy().into_owned()
    };
    let dimensions = if v1.dimensions.is_null() {
        Vec::new()
    } else {
        std::slice::from_raw_parts(v1.dimensions, v1.rank as usize).to_vec()
    };
    let element = element_bytes(v1.dataType)
        .ok_or_else(|| format!("{name}: unsupported data type {:#x}", v1.dataType))?;
    let parameters = &v1.quantizeParams;
    let scale_offset = (parameters.encodingDefinition == QNN_DEFINITION_DEFINED
        && parameters.quantizationEncoding == QNN_QUANTIZATION_ENCODING_SCALE_OFFSET)
        .then(|| {
            let encoding = parameters.__bindgen_anon_1.scaleOffsetEncoding;
            (encoding.scale, encoding.offset)
        });
    let bytes = dimensions.iter().map(|&d| d as usize).product::<usize>() * element;
    Ok(Tensor {
        name,
        dimensions,
        scale_offset,
        unsigned_8bit: is_unsigned_8bit(v1.dataType),
        bytes,
        raw: *raw,
    })
}

unsafe fn describe_all(tensors: *const Qnn_Tensor_t, count: u32) -> Result<Vec<Tensor>, String> {
    if tensors.is_null() {
        return Ok(Vec::new());
    }
    std::slice::from_raw_parts(tensors, count as usize)
        .iter()
        .map(|t| describe(t))
        .collect()
}

/// The first graph's name, inputs and outputs, from the binary's description.
unsafe fn first_graph(
    info: &QnnSystemContext_BinaryInfo_t,
) -> Result<(*const std::os::raw::c_char, Vec<Tensor>, Vec<Tensor>), String> {
    let (count, graphs) = match info.version {
        QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_1 => {
            let v = &info.__bindgen_anon_1.contextBinaryInfoV1;
            (v.numGraphs, v.graphs)
        }
        QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_2 => {
            let v = &info.__bindgen_anon_1.contextBinaryInfoV2;
            (v.numGraphs, v.graphs)
        }
        QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_3 => {
            let v = &info.__bindgen_anon_1.contextBinaryInfoV3;
            (v.numGraphs, v.graphs)
        }
        version => return Err(format!("unknown context binary info version {version}")),
    };
    if count == 0 || graphs.is_null() {
        return Err("the context binary holds no graph".to_string());
    }
    let graph = &*graphs;
    macro_rules! graph_fields {
        ($v:expr) => {
            (
                $v.graphName,
                describe_all($v.graphInputs, $v.numGraphInputs)?,
                describe_all($v.graphOutputs, $v.numGraphOutputs)?,
            )
        };
    }
    Ok(match graph.version {
        QNN_SYSTEM_CONTEXT_GRAPH_INFO_VERSION_1 => {
            graph_fields!(graph.__bindgen_anon_1.graphInfoV1)
        }
        QNN_SYSTEM_CONTEXT_GRAPH_INFO_VERSION_2 => {
            graph_fields!(graph.__bindgen_anon_1.graphInfoV2)
        }
        QNN_SYSTEM_CONTEXT_GRAPH_INFO_VERSION_3 => {
            graph_fields!(graph.__bindgen_anon_1.graphInfoV3)
        }
        version => return Err(format!("unknown graph info version {version}")),
    })
}

impl Model {
    /// Loads the HTP backend and creates the context `binary` holds.
    pub fn open(binary: &[u8]) -> Result<Model, String> {
        unsafe {
            let backend_library =
                Library::new("libQnnHtp.so").map_err(|e| format!("libQnnHtp.so: {e}"))?;
            let system_library =
                Library::new("libQnnSystem.so").map_err(|e| format!("libQnnSystem.so: {e}"))?;

            let get_providers: libloading::Symbol<GetProviders> = backend_library
                .get(b"QnnInterface_getProviders\0")
                .map_err(|e| format!("QnnInterface_getProviders: {e}"))?;
            let mut providers: *mut *const QnnInterface_t = ptr::null_mut();
            let mut count = 0u32;
            check(
                "QnnInterface_getProviders",
                get_providers(&mut providers, &mut count),
            )?;
            let interface = std::slice::from_raw_parts(providers, count as usize)
                .iter()
                .map(|&provider| &*provider)
                .find(|provider| provider.apiVersion.coreApiVersion.major == QNN_API_VERSION_MAJOR)
                .ok_or("libQnnHtp.so offers no interface of this QNN API version")?
                .__bindgen_anon_1
                .v2_39;

            let get_system_providers: libloading::Symbol<GetSystemProviders> = system_library
                .get(b"QnnSystemInterface_getProviders\0")
                .map_err(|e| format!("QnnSystemInterface_getProviders: {e}"))?;
            let mut system_providers: *mut *const QnnSystemInterface_t = ptr::null_mut();
            check(
                "QnnSystemInterface_getProviders",
                get_system_providers(&mut system_providers, &mut count),
            )?;
            let system = std::slice::from_raw_parts(system_providers, count as usize)
                .iter()
                .map(|&provider| &*provider)
                .find(|provider| provider.systemApiVersion.major == QNN_SYSTEM_API_VERSION_MAJOR)
                .ok_or("libQnnSystem.so offers no interface of this QNN system API version")?
                .__bindgen_anon_1
                .v1_14;

            // The binary's description stays in the system context, which lives
            // as long as the process: the tensors point into it.
            let mut system_context: QnnSystemContext_Handle_t = ptr::null_mut();
            check(
                "systemContextCreate",
                system
                    .systemContextCreate
                    .ok_or_else(|| missing("systemContextCreate"))?(
                    &mut system_context
                ),
            )?;
            let mut info: *const QnnSystemContext_BinaryInfo_t = ptr::null();
            let mut info_size: Qnn_ContextBinarySize_t = 0;
            check(
                "systemContextGetBinaryInfo",
                system
                    .systemContextGetBinaryInfo
                    .ok_or_else(|| missing("systemContextGetBinaryInfo"))?(
                    system_context,
                    binary.as_ptr() as *mut c_void,
                    binary.len() as u64,
                    &mut info,
                    &mut info_size,
                ),
            )?;
            let (graph_name, inputs, outputs) = first_graph(&*info)?;

            let mut backend: Qnn_BackendHandle_t = ptr::null_mut();
            check(
                "backendCreate",
                interface
                    .backendCreate
                    .ok_or_else(|| missing("backendCreate"))?(
                    ptr::null_mut(),
                    ptr::null_mut(),
                    &mut backend,
                ),
            )?;
            let mut device: Qnn_DeviceHandle_t = ptr::null_mut();
            if let Some(device_create) = interface.deviceCreate {
                check(
                    "deviceCreate",
                    device_create(ptr::null_mut(), ptr::null_mut(), &mut device),
                )?;
            }
            let mut context: Qnn_ContextHandle_t = ptr::null_mut();
            check(
                "contextCreateFromBinary",
                interface
                    .contextCreateFromBinary
                    .ok_or_else(|| missing("contextCreateFromBinary"))?(
                    backend,
                    device,
                    ptr::null_mut(),
                    binary.as_ptr() as *const c_void,
                    binary.len() as u64,
                    &mut context,
                    ptr::null_mut(),
                ),
            )?;
            let mut graph: Qnn_GraphHandle_t = ptr::null_mut();
            check(
                "graphRetrieve",
                interface
                    .graphRetrieve
                    .ok_or_else(|| missing("graphRetrieve"))?(
                    context, graph_name, &mut graph
                ),
            )?;

            let (profile, profile_error) = match create_profile(&interface, backend) {
                Ok(handle) => (
                    Some(Profile {
                        handle,
                        cursor: EventCursor::default(),
                    }),
                    None,
                ),
                Err(message) => (None, Some(message)),
            };

            Ok(Model {
                interface,
                graph,
                inputs,
                outputs,
                profile,
                profile_error,
                profile_report: None,
                profile_reported: false,
                backend,
                _context: context,
                _libraries: [backend_library, system_library],
            })
        }
    }

    /// The first profiled execution's events, `(type, unit, value)` each, once.
    pub fn take_profile_report(&mut self) -> Option<String> {
        self.profile_report.take()
    }

    /// Runs the graph on `inputs`, filling `outputs`, each the size of its tensor,
    /// and returns the accelerator's time, or the wall time around `graphExecute`
    /// when the profile does not report it.
    pub fn execute(
        &mut self,
        inputs: &mut [&mut [u8]],
        outputs: &mut [&mut [u8]],
    ) -> Result<Timing, String> {
        let bind =
            |tensors: &[Tensor], buffers: &mut [&mut [u8]]| -> Result<Vec<Qnn_Tensor_t>, String> {
                tensors
                    .iter()
                    .zip(buffers.iter_mut())
                    .map(|(tensor, buffer)| {
                        if buffer.len() != tensor.bytes {
                            return Err(format!(
                                "{}: {} bytes for a {}-byte tensor",
                                tensor.name,
                                buffer.len(),
                                tensor.bytes
                            ));
                        }
                        let mut raw = tensor.raw;
                        // Version 2 begins with version 1's fields.
                        let v1 = unsafe { &mut raw.__bindgen_anon_1.v1 };
                        v1.memType = QNN_TENSORMEMTYPE_RAW;
                        v1.__bindgen_anon_1.clientBuf = Qnn_ClientBuffer_t {
                            data: buffer.as_mut_ptr() as *mut c_void,
                            dataSize: buffer.len() as u32,
                        };
                        Ok(raw)
                    })
                    .collect()
            };
        let inputs = bind(&self.inputs, inputs)?;
        let mut outputs = bind(&self.outputs, outputs)?;
        let graph_execute = self
            .interface
            .graphExecute
            .ok_or_else(|| missing("graphExecute"))?;
        let profile_handle = self
            .profile
            .as_ref()
            .map_or(ptr::null_mut(), |profile| profile.handle);
        let started = Instant::now();
        let executed = check("graphExecute", unsafe {
            graph_execute(
                self.graph,
                inputs.as_ptr(),
                inputs.len() as u32,
                outputs.as_mut_ptr(),
                outputs.len() as u32,
                profile_handle,
                ptr::null_mut(),
            )
        });
        if executed.is_err() {
            // A failed execution may have stored events the cursor cannot place.
            self.replace_profile();
        }
        executed?;
        let wall_micros = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
        Ok(match self.profiled_micros() {
            Some(micros) => Timing {
                micros,
                source: TimeSource::Accelerator,
            },
            None => Timing {
                micros: wall_micros,
                source: TimeSource::WallTime,
            },
        })
    }

    /// The latest execution's accelerator time from the profile. The handle is
    /// replaced every `EXECUTIONS_PER_PROFILE` executions, and as soon as it stores
    /// no more events.
    fn profiled_micros(&mut self) -> Option<u64> {
        let profile = self.profile.as_mut()?;
        let interface = &self.interface;
        let top_level = unsafe { top_level_events(interface, profile.handle) };
        let latest = profile.cursor.latest_execution(top_level.len());
        let replace = latest.is_none() || profile.cursor.executions >= EXECUTIONS_PER_PROFILE;
        let mut events = Vec::new();
        for &id in &top_level[latest.unwrap_or_default()] {
            unsafe { collect_events(interface, id, &mut events) };
        }
        if !self.profile_reported && !events.is_empty() {
            self.profile_reported = true;
            self.profile_report = Some(format!(
                "{:?}",
                events
                    .iter()
                    .map(|event| (event.kind, event.unit, event.value))
                    .collect::<Vec<_>>()
            ));
        }
        if replace {
            self.replace_profile();
        }
        accelerator_micros(&events)
    }

    /// A fresh profile handle in place of the current one, or none, the reason in
    /// `profile_error`, when either step fails.
    fn replace_profile(&mut self) {
        let Some(profile) = self.profile.take() else {
            return;
        };
        let freed = match self.interface.profileFree {
            Some(profile_free) => check("profileFree", unsafe { profile_free(profile.handle) }),
            None => Err(missing("profileFree")),
        };
        match freed.and_then(|()| create_profile(&self.interface, self.backend)) {
            Ok(handle) => {
                self.profile = Some(Profile {
                    handle,
                    cursor: EventCursor::default(),
                })
            }
            Err(message) => self.profile_error = Some(message),
        }
    }
}

/// A basic-level profile handle on `backend`.
fn create_profile(
    interface: &QnnInterface_ImplementationV2_39_t,
    backend: Qnn_BackendHandle_t,
) -> Result<Qnn_ProfileHandle_t, String> {
    let profile_create = interface
        .profileCreate
        .ok_or_else(|| missing("profileCreate"))?;
    let mut handle: Qnn_ProfileHandle_t = ptr::null_mut();
    check("profileCreate", unsafe {
        profile_create(backend, QNN_PROFILE_LEVEL_BASIC, &mut handle)
    })?;
    Ok(handle)
}

/// The profile's top-level events; none when they cannot be read.
unsafe fn top_level_events(
    interface: &QnnInterface_ImplementationV2_39_t,
    profile: Qnn_ProfileHandle_t,
) -> Vec<QnnProfile_EventId_t> {
    let Some(get_events) = interface.profileGetEvents else {
        return Vec::new();
    };
    let mut ids: *const QnnProfile_EventId_t = ptr::null();
    let mut count = 0u32;
    if get_events(profile, &mut ids, &mut count) != 0 || ids.is_null() {
        return Vec::new();
    }
    std::slice::from_raw_parts(ids, count as usize).to_vec()
}

/// `id`'s data, then its sub-events', depth first; an event whose data cannot be
/// read is skipped.
unsafe fn collect_events(
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
    use super::*;

    #[test]
    fn element_sizes_follow_the_data_type_low_byte() {
        assert_eq!(element_bytes(QNN_DATATYPE_UFIXED_POINT_8), Some(1));
        assert_eq!(element_bytes(QNN_DATATYPE_FLOAT_32), Some(4));
        assert_eq!(element_bytes(QNN_DATATYPE_INT_16), Some(2));
    }

    #[test]
    fn unsigned_8_bit_types_are_the_quantised_and_the_plain_ones() {
        assert!(is_unsigned_8bit(QNN_DATATYPE_UFIXED_POINT_8));
        assert!(is_unsigned_8bit(QNN_DATATYPE_UINT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_SFIXED_POINT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_INT_8));
        assert!(!is_unsigned_8bit(QNN_DATATYPE_UFIXED_POINT_16));
    }

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
