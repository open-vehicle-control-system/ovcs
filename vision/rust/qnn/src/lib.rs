//! A QNN context binary run on the HTP backend, through QAIRT's shared
//! libraries loaded at run time from the library path. Each execution is timed
//! by QNN's basic profiling, the HTP's own execution time, or by the wall time
//! around `graphExecute` when the profile is unavailable; `TimeLog` says which.
//! The HTP runs under the power vote of a performance profile (`Performance`).

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

mod performance;
pub mod port;
mod stage_times;
mod time_log;

pub use performance::{command_line, CommandLine, Performance, DEFAULT_PERFORMANCE};
pub use stage_times::{micros, Stage, StageTimes, STAGE_TIMES_EVERY};
pub use time_log::TimeLog;

use std::ffi::{c_void, CStr, CString};
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
#[derive(Clone, Debug, PartialEq)]
pub struct Tensor {
    pub name: String,
    pub dimensions: Vec<u32>,
    /// `(scale, offset)`: a value `q` stands for `(q + offset) × scale`.
    pub scale_offset: Option<(f32, i32)>,
    /// Whether an element is one unsigned byte, quantised or not.
    pub unsigned_8bit: bool,
    pub bytes: usize,
}

/// How far a pixel value's scale times 255 may be from 1.
const PIXEL_SCALE_TOLERANCE: f32 = 1e-2;

impl Tensor {
    /// Whether the input reads its bytes as the pixel values they are: unquantised, or with
    /// a scale of 1/255 and an offset of 0. `Err` names the quantisation that does not.
    pub fn check_takes_pixel_values(&self) -> Result<(), String> {
        match self.scale_offset {
            Some((scale, offset))
                if offset != 0 || (scale * 255.0 - 1.0).abs() > PIXEL_SCALE_TOLERANCE =>
            {
                Err(format!(
                    "input {} has a scale of {scale} and an offset of {offset}, not a scale \
                     of 1/255 and an offset of 0: it is fed pixel values from 0 to 255",
                    self.name
                ))
            }
            _ => Ok(()),
        }
    }
}

/// A graph's inputs or outputs, and QNN's tensor each is described from, in the same order.
#[derive(Default)]
struct Tensors {
    described: Vec<Tensor>,
    raw: Vec<Qnn_Tensor_t>,
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
    fn of(events: &[ProfileEvent]) -> ProfiledTimes {
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
struct ProfileEvent {
    kind: QnnProfile_EventType_t,
    unit: QnnProfile_EventUnit_t,
    value: QnnProfile_EventValue_t,
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
    session: Session,
    graph: Qnn_GraphHandle_t,
    pub graph_name: String,
    pub inputs: Vec<Tensor>,
    pub outputs: Vec<Tensor>,
    // QNN's tensors point into the session's system context: valid as long as `session`.
    raw_inputs: Vec<Qnn_Tensor_t>,
    raw_outputs: Vec<Qnn_Tensor_t>,
    /// Why executions are timed by the wall time, once the profile is unavailable.
    pub profile_error: Option<String>,
    /// The first profiled execution's events, until `take_profile_report`.
    profile_report: Option<String>,
    profile_reported: bool,
    /// Why the performance profile's vote is missing or partial, if it is.
    pub power_vote_error: Option<String>,
}

/// The QNN libraries and what a model creates in them, each handle null until it is created.
struct Session {
    interface: QnnInterface_ImplementationV2_39_t,
    system: QnnSystemInterface_ImplementationV1_14_t,
    system_context: QnnSystemContext_Handle_t,
    backend: Qnn_BackendHandle_t,
    device: Qnn_DeviceHandle_t,
    // Destroyed before the libraries are unloaded.
    power_vote: Option<PowerVote>,
    context: Qnn_ContextHandle_t,
    profile: Option<Profile>,
    _libraries: [Library; 2],
}

/// A power config id holding a performance profile's vote, which ends when it is destroyed.
struct PowerVote {
    destroy: QnnHtpPerfInfrastructure_DestroyPowerConfigIdFn_t,
    id: u32,
}

impl Drop for PowerVote {
    fn drop(&mut self) {
        if let Some(destroy) = self.destroy {
            // SAFETY: the session destroys the vote while its library is loaded, and `id`
            // is the one that library created.
            unsafe { destroy(self.id) };
        }
    }
}

/// The calls of a performance profile's vote, in `Performance::power_configs`' order.
const POWER_CONFIG_CALLS: [&str; 3] = [
    "setPowerConfig DCVS_V3",
    "setPowerConfig RPC_CONTROL_LATENCY",
    "setPowerConfig RPC_POLLING_TIME",
];

/// Votes `performance` on the HTP through the device's performance infrastructure. The vote
/// holds while the returned id lives; there is none when the DCVS_V3 call fails. The message
/// names each call that failed.
///
/// # Safety
/// `interface` is of a library still loaded, after its `deviceCreate`.
unsafe fn vote(
    interface: &QnnInterface_ImplementationV2_39_t,
    performance: Performance,
) -> (Option<PowerVote>, Option<String>) {
    let unvoted = |message: String| {
        (
            None,
            Some(format!(
                "{message}; the HTP runs under its default power policy"
            )),
        )
    };
    if performance == Performance::NoVote {
        return (None, None);
    }
    let Some(get_infrastructure) = interface.deviceGetInfrastructure else {
        return unvoted(missing("deviceGetInfrastructure"));
    };
    let mut infrastructure: QnnDevice_Infrastructure_t = ptr::null_mut();
    // QNN writes the infrastructure through the pointer its header declares const.
    let written = ptr::addr_of_mut!(infrastructure).cast_const();
    if let Err(message) = check("deviceGetInfrastructure", get_infrastructure(written)) {
        return unvoted(message);
    }
    if infrastructure.is_null() {
        return unvoted("deviceGetInfrastructure gave no infrastructure".to_string());
    }
    let htp = &*(infrastructure as *const QnnHtpDevice_Infrastructure_t);
    if htp.infraType != QNN_HTP_DEVICE_INFRASTRUCTURE_TYPE_PERF {
        return unvoted(format!(
            "the device's infrastructure is of type {}, not the HTP's performance one",
            htp.infraType
        ));
    }
    let performance_infrastructure = htp.__bindgen_anon_1.perfInfra;
    let (Some(create), Some(set)) = (
        performance_infrastructure.createPowerConfigId,
        performance_infrastructure.setPowerConfig,
    ) else {
        return unvoted(missing("createPowerConfigId or setPowerConfig"));
    };
    let mut id = 0u32;
    if let Err(message) = check("createPowerConfigId", create(0, 0, &mut id)) {
        return unvoted(message);
    }
    let held = PowerVote {
        destroy: performance_infrastructure.destroyPowerConfigId,
        id,
    };
    let mut failures = Vec::new();
    for (config, call) in performance.power_configs(id).iter().zip(POWER_CONFIG_CALLS) {
        let mut configs = [
            config as *const QnnHtpPerfInfrastructure_PowerConfig_t,
            ptr::null(),
        ];
        if let Err(message) = check(call, set(id, configs.as_mut_ptr())) {
            if call == POWER_CONFIG_CALLS[0] {
                return unvoted(message);
            }
            failures.push(message);
        }
    }
    let error = (!failures.is_empty()).then(|| failures.join(", "));
    (Some(held), error)
}

/// The interface of `libQnnHtp.so` of this QNN API version.
///
/// # Safety
/// `library` is `libQnnHtp.so`, and the interface is used only while it stays loaded.
unsafe fn backend_interface(
    library: &Library,
) -> Result<QnnInterface_ImplementationV2_39_t, String> {
    let get_providers: libloading::Symbol<GetProviders> = library
        .get(b"QnnInterface_getProviders\0")
        .map_err(|e| format!("QnnInterface_getProviders: {e}"))?;
    let mut providers: *mut *const QnnInterface_t = ptr::null_mut();
    let mut count = 0u32;
    check(
        "QnnInterface_getProviders",
        get_providers(&mut providers, &mut count),
    )?;
    let built = (QNN_API_VERSION_MAJOR, QNN_API_VERSION_MINOR);
    let providers = offered("libQnnHtp.so", providers, count)?;
    let version = |provider: &&QnnInterface_t| provider.apiVersion.coreApiVersion;
    match providers
        .iter()
        .find(|provider| serves(&version(provider), built))
    {
        Some(provider) => Ok(provider.__bindgen_anon_1.v2_39),
        None => {
            let offered: Vec<_> = providers.iter().map(version).collect();
            Err(unserved("libQnnHtp.so", "QNN API", &offered, built))
        }
    }
}

/// The interface providers `library` gave: `count` of them at `providers`.
///
/// # Safety
/// `providers` is null or the array of `count` pointers the library's `getProviders` gave,
/// each null or to a provider that lives as long as the library stays loaded.
unsafe fn offered<'library, Provider>(
    library: &str,
    providers: *mut *const Provider,
    count: u32,
) -> Result<Vec<&'library Provider>, String> {
    let none = || format!("{library} gave no interface provider");
    if providers.is_null() {
        return Err(none());
    }
    std::slice::from_raw_parts(providers, count as usize)
        .iter()
        .map(|&provider| provider.as_ref().ok_or_else(none))
        .collect()
}

/// Whether a library whose interface is of API version `offered` has every function a build
/// against the `(major, minor)` of `built` reads: an interface gains functions at its end
/// with each minor version, so an older library's is shorter than the build's.
fn serves(offered: &Qnn_Version_t, (major, minor): (u32, u32)) -> bool {
    offered.major == major && offered.minor >= minor
}

/// The error of a `library` none of whose `offered` versions of `api` serves the build's.
fn unserved(
    library: &str,
    api: &str,
    offered: &[Qnn_Version_t],
    (major, minor): (u32, u32),
) -> String {
    let offered: Vec<String> = (offered.iter())
        .map(|version| format!("{}.{}", version.major, version.minor))
        .collect();
    format!(
        "{library} offers the {api} {}, not {major}.{minor} or a later {major}.x",
        offered.join(", ")
    )
}

/// The interface of `libQnnSystem.so` of this QNN system API version.
///
/// # Safety
/// `library` is `libQnnSystem.so`, and the interface is used only while it stays loaded.
unsafe fn system_interface(
    library: &Library,
) -> Result<QnnSystemInterface_ImplementationV1_14_t, String> {
    let get_system_providers: libloading::Symbol<GetSystemProviders> = library
        .get(b"QnnSystemInterface_getProviders\0")
        .map_err(|e| format!("QnnSystemInterface_getProviders: {e}"))?;
    let mut system_providers: *mut *const QnnSystemInterface_t = ptr::null_mut();
    let mut count = 0u32;
    check(
        "QnnSystemInterface_getProviders",
        get_system_providers(&mut system_providers, &mut count),
    )?;
    let built = (QNN_SYSTEM_API_VERSION_MAJOR, QNN_SYSTEM_API_VERSION_MINOR);
    let providers = offered("libQnnSystem.so", system_providers, count)?;
    let version = |provider: &&QnnSystemInterface_t| provider.systemApiVersion;
    match providers
        .iter()
        .find(|provider| serves(&version(provider), built))
    {
        Some(provider) => Ok(provider.__bindgen_anon_1.v1_14),
        None => {
            let offered: Vec<_> = providers.iter().map(version).collect();
            Err(unserved(
                "libQnnSystem.so",
                "QNN system API",
                &offered,
                built,
            ))
        }
    }
}

/// The names of the graphs the DLC at `path` holds, as QNN's system library reads them.
pub fn dlc_graph_names(path: &str) -> Result<Vec<String>, String> {
    let terminated_path =
        CString::new(path).map_err(|_| format!("{path}: a path holding a NUL"))?;
    // SAFETY: the library stays loaded to the end of the block, past the DLC's free, and
    // the names are copied out of it before.
    unsafe {
        let library =
            Library::new("libQnnSystem.so").map_err(|e| format!("libQnnSystem.so: {e}"))?;
        let system = system_interface(&library)?;
        let mut dlc: QnnSystemDlc_Handle_t = ptr::null_mut();
        check(
            "systemDlcCreateFromFile",
            system
                .systemDlcCreateFromFile
                .ok_or_else(|| missing("systemDlcCreateFromFile"))?(
                ptr::null_mut(),
                terminated_path.as_ptr(),
                &mut dlc,
            ),
        )?;
        let names = composable_graph_names(&system, dlc);
        if let Some(free) = system.systemDlcFree {
            free(dlc);
        }
        names
    }
}

/// Prints the names of the graphs the DLC at `path` holds on stdout, one a line: a Port's
/// answer to `--graph-names`.
pub fn print_dlc_graph_names(path: &str) -> Result<(), String> {
    let names = dlc_graph_names(path)?;
    if names.is_empty() {
        return Err(format!("{path} holds no graph"));
    }
    for name in names {
        println!("{name}");
    }
    Ok(())
}

/// # Safety
/// `dlc` is a handle `system` created and has not freed.
unsafe fn composable_graph_names(
    system: &QnnSystemInterface_ImplementationV1_14_t,
    dlc: QnnSystemDlc_Handle_t,
) -> Result<Vec<String>, String> {
    let get_handles = system
        .systemDlcGetComposableGraphInfoHandles
        .ok_or_else(|| missing("systemDlcGetComposableGraphInfoHandles"))?;
    let get_name = system
        .systemDlcGetComposableGraphInfoGraphName
        .ok_or_else(|| missing("systemDlcGetComposableGraphInfoGraphName"))?;
    let mut handles: *mut QnnSystemDlc_GraphInfoHandle_t = ptr::null_mut();
    let mut count = 0u32;
    check(
        "systemDlcGetComposableGraphInfoHandles",
        get_handles(dlc, &mut handles, &mut count),
    )?;
    if handles.is_null() {
        return Ok(Vec::new());
    }
    std::slice::from_raw_parts(handles, count as usize)
        .iter()
        .map(|&handle| {
            let mut name: *const std::os::raw::c_char = ptr::null();
            check(
                "systemDlcGetComposableGraphInfoGraphName",
                get_name(handle, &mut name),
            )?;
            if name.is_null() {
                return Err("a graph of the DLC has no name".to_string());
            }
            Ok(CStr::from_ptr(name).to_string_lossy().into_owned())
        })
        .collect()
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
///
/// # Safety
/// `tensor` is of version 1 or 2.
unsafe fn fields(tensor: &Qnn_Tensor_t) -> &Qnn_TensorV1_t {
    &tensor.__bindgen_anon_1.v1
}

/// # Safety
/// `raw` is a tensor QNN described, its name and dimensions still allocated.
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
    })
}

/// # Safety
/// `tensors` is null or points to `count` tensors as `describe` takes them.
unsafe fn describe_all(tensors: *const Qnn_Tensor_t, count: u32) -> Result<Tensors, String> {
    if tensors.is_null() {
        return Ok(Tensors::default());
    }
    let raw = std::slice::from_raw_parts(tensors, count as usize).to_vec();
    let described = raw
        .iter()
        .map(|raw| describe(raw))
        .collect::<Result<_, _>>()?;
    Ok(Tensors { described, raw })
}

/// The first graph's name, inputs and outputs, from the binary's description.
///
/// # Safety
/// `info` is a description a system context gave and still holds.
unsafe fn first_graph(
    info: &QnnSystemContext_BinaryInfo_t,
) -> Result<(*const std::os::raw::c_char, Tensors, Tensors), String> {
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
                if $v.graphName.is_null() {
                    return Err("the context binary's first graph has no name".to_string());
                } else {
                    $v.graphName
                },
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

impl Session {
    /// The HTP backend's and the system's libraries, loaded, with their interfaces.
    ///
    /// # Safety
    /// Loading runs the libraries' initialisers; nothing else is asked of the caller.
    unsafe fn load() -> Result<Session, String> {
        let backend_library =
            Library::new("libQnnHtp.so").map_err(|e| format!("libQnnHtp.so: {e}"))?;
        let system_library =
            Library::new("libQnnSystem.so").map_err(|e| format!("libQnnSystem.so: {e}"))?;
        Ok(Session {
            interface: backend_interface(&backend_library)?,
            system: system_interface(&system_library)?,
            system_context: ptr::null_mut(),
            backend: ptr::null_mut(),
            device: ptr::null_mut(),
            power_vote: None,
            context: ptr::null_mut(),
            profile: None,
            _libraries: [backend_library, system_library],
        })
    }

    /// `binary`'s description, which stays in the system context: the tensors point into it.
    ///
    /// # Safety
    /// Called once, on a session just loaded.
    unsafe fn describe_binary(
        &mut self,
        binary: &[u8],
    ) -> Result<*const QnnSystemContext_BinaryInfo_t, String> {
        check(
            "systemContextCreate",
            self.system
                .systemContextCreate
                .ok_or_else(|| missing("systemContextCreate"))?(
                &mut self.system_context
            ),
        )?;
        let mut info: *const QnnSystemContext_BinaryInfo_t = ptr::null();
        let mut info_size: Qnn_ContextBinarySize_t = 0;
        check(
            "systemContextGetBinaryInfo",
            self.system
                .systemContextGetBinaryInfo
                .ok_or_else(|| missing("systemContextGetBinaryInfo"))?(
                self.system_context,
                binary.as_ptr() as *mut c_void,
                binary.len() as u64,
                &mut info,
                &mut info_size,
            ),
        )?;
        Ok(info)
    }

    /// Creates the backend and, where the library has one, its device.
    ///
    /// # Safety
    /// Called once, on a session without a backend.
    unsafe fn create_backend(&mut self) -> Result<(), String> {
        check(
            "backendCreate",
            self.interface
                .backendCreate
                .ok_or_else(|| missing("backendCreate"))?(
                ptr::null_mut(),
                ptr::null_mut(),
                &mut self.backend,
            ),
        )?;
        if let Some(device_create) = self.interface.deviceCreate {
            check(
                "deviceCreate",
                device_create(ptr::null_mut(), ptr::null_mut(), &mut self.device),
            )?;
        }
        Ok(())
    }

    /// Creates the context `binary` holds on the backend and its device.
    ///
    /// # Safety
    /// Called once, after `create_backend`.
    unsafe fn create_context(&mut self, binary: &[u8]) -> Result<(), String> {
        check(
            "contextCreateFromBinary",
            self.interface
                .contextCreateFromBinary
                .ok_or_else(|| missing("contextCreateFromBinary"))?(
                self.backend,
                self.device,
                ptr::null_mut(),
                binary.as_ptr() as *const c_void,
                binary.len() as u64,
                &mut self.context,
                ptr::null_mut(),
            ),
        )
    }

    /// The context's graph named `name`.
    ///
    /// # Safety
    /// Called after `create_context`, `name` a NUL-terminated string.
    unsafe fn retrieve_graph(
        &self,
        name: *const std::os::raw::c_char,
    ) -> Result<Qnn_GraphHandle_t, String> {
        let mut graph: Qnn_GraphHandle_t = ptr::null_mut();
        check(
            "graphRetrieve",
            self.interface
                .graphRetrieve
                .ok_or_else(|| missing("graphRetrieve"))?(
                self.context, name, &mut graph
            ),
        )?;
        Ok(graph)
    }

    /// A fresh basic-level profile handle as the session's, or none and why.
    fn create_profile(&mut self) -> Result<(), String> {
        let handle = create_profile(&self.interface, self.backend)?;
        self.profile = Some(Profile {
            handle,
            cursor: EventCursor::default(),
        });
        Ok(())
    }
}

impl Model {
    /// Loads the HTP backend, votes `performance` on it, and creates the context `binary`
    /// holds. A vote that fails leaves the HTP under its default power policy, the reason in
    /// `power_vote_error`.
    pub fn open(binary: &[u8], performance: Performance) -> Result<Model, String> {
        // SAFETY: the steps run once each in the order they depend on, on handles the
        // session's libraries gave; `info`, the graph's name and the tensors' pointers
        // belong to the system context, which the session keeps with them.
        unsafe {
            let mut session = Session::load()?;
            let info = session.describe_binary(binary)?;
            let info = info
                .as_ref()
                .ok_or("systemContextGetBinaryInfo gave no description")?;
            let (graph_name, inputs, outputs) = first_graph(info)?;
            let graph_name_text = CStr::from_ptr(graph_name).to_string_lossy().into_owned();
            session.create_backend()?;
            let (power_vote, power_vote_error) = vote(&session.interface, performance);
            session.power_vote = power_vote;
            session.create_context(binary)?;
            let graph = session.retrieve_graph(graph_name)?;
            let profile_error = session.create_profile().err();
            Ok(Model {
                session,
                graph,
                graph_name: graph_name_text,
                inputs: inputs.described,
                outputs: outputs.described,
                raw_inputs: inputs.raw,
                raw_outputs: outputs.raw,
                profile_error,
                profile_report: None,
                profile_reported: false,
                power_vote_error,
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
        let inputs = bind(&self.inputs, &self.raw_inputs, inputs)?;
        let mut outputs = bind(&self.outputs, &self.raw_outputs, outputs)?;
        let graph_execute = self
            .session
            .interface
            .graphExecute
            .ok_or_else(|| missing("graphExecute"))?;
        let profile_handle = self
            .session
            .profile
            .as_ref()
            .map_or(ptr::null_mut(), |profile| profile.handle);
        let started = Instant::now();
        // SAFETY: the graph and the profile are the session's; each tensor is QNN's own
        // description on a buffer of its size that outlives the call.
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
        let graph_execute_micros = micros(started.elapsed());
        let reading = Instant::now();
        let profiled = self.profiled_times();
        let profile_read_micros = micros(reading.elapsed());
        let (micros, source) = match profiled.accelerator_micros {
            Some(micros) => (micros, TimeSource::Accelerator),
            None => (graph_execute_micros, TimeSource::WallTime),
        };
        Ok(Timing {
            micros,
            source,
            graph_execute_micros,
            profile_read_micros,
            profiled,
        })
    }

    /// The latest execution's times from the profile. The handle is replaced every
    /// `EXECUTIONS_PER_PROFILE` executions, and as soon as it stores no more events.
    fn profiled_times(&mut self) -> ProfiledTimes {
        let session = &mut self.session;
        let Some(profile) = session.profile.as_mut() else {
            return ProfiledTimes::default();
        };
        let interface = &session.interface;
        // SAFETY: the handle is the session's live profile.
        let top_level = unsafe { top_level_events(interface, profile.handle) };
        let latest = profile.cursor.latest_execution(top_level.len());
        let replace = latest.is_none() || profile.cursor.executions >= EXECUTIONS_PER_PROFILE;
        let mut events = Vec::new();
        for &id in &top_level[latest.unwrap_or_default()] {
            // SAFETY: the profile that gave `id` is still alive.
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
        ProfiledTimes::of(&events)
    }

    /// A fresh profile handle in place of the current one, or none, the reason in
    /// `profile_error`, when either step fails.
    fn replace_profile(&mut self) {
        let Some(profile) = self.session.profile.take() else {
            return;
        };
        let freed = match self.session.interface.profileFree {
            // SAFETY: the handle is one this interface created, freed once: it was taken.
            Some(profile_free) => check("profileFree", unsafe { profile_free(profile.handle) }),
            None => Err(missing("profileFree")),
        };
        if let Err(message) = freed.and_then(|()| self.session.create_profile()) {
            self.profile_error = Some(message);
        }
    }
}

/// QNN's tensors `raw`, which `tensors` describe, each on the buffer of `buffers` in its place.
fn bind(
    tensors: &[Tensor],
    raw: &[Qnn_Tensor_t],
    buffers: &mut [&mut [u8]],
) -> Result<Vec<Qnn_Tensor_t>, String> {
    (tensors.iter().zip(raw))
        .zip(buffers.iter_mut())
        .map(|((tensor, raw), buffer)| {
            if buffer.len() != tensor.bytes {
                return Err(format!(
                    "{}: {} bytes for a {}-byte tensor",
                    tensor.name,
                    buffer.len(),
                    tensor.bytes
                ));
            }
            let mut raw = *raw;
            // SAFETY: version 2 begins with version 1's fields, which are plain data.
            let v1 = unsafe { &mut raw.__bindgen_anon_1.v1 };
            v1.memType = QNN_TENSORMEMTYPE_RAW;
            v1.__bindgen_anon_1.clientBuf = Qnn_ClientBuffer_t {
                data: buffer.as_mut_ptr() as *mut c_void,
                dataSize: buffer.len() as u32,
            };
            Ok(raw)
        })
        .collect()
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
    // SAFETY: `backend` is the session's live backend, and QNN writes only the handle.
    check("profileCreate", unsafe {
        profile_create(backend, QNN_PROFILE_LEVEL_BASIC, &mut handle)
    })?;
    Ok(handle)
}

/// The profile's top-level events; none when they cannot be read.
///
/// # Safety
/// `profile` is a live handle of `interface`'s library.
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
///
/// # Safety
/// `id` is an event of a profile handle still alive.
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

    #[test]
    fn a_library_serves_a_build_of_its_major_and_at_most_its_minor() {
        let offered = |major, minor| Qnn_Version_t {
            major,
            minor,
            patch: 0,
        };
        assert!(serves(&offered(2, 39), (2, 39)));
        assert!(serves(&offered(2, 41), (2, 39)));
        assert!(!serves(&offered(2, 38), (2, 39)));
        assert!(!serves(&offered(3, 39), (2, 39)));
        assert!(!serves(&offered(1, 50), (2, 39)));
    }

    #[test]
    fn a_library_without_the_builds_api_names_what_it_offers() {
        let offered = [(2, 31), (1, 9)].map(|(major, minor)| Qnn_Version_t {
            major,
            minor,
            patch: 7,
        });
        assert_eq!(
            unserved("libQnnHtp.so", "QNN API", &offered, (2, 39)),
            "libQnnHtp.so offers the QNN API 2.31, 1.9, not 2.39 or a later 2.x"
        );
    }

    #[test]
    fn a_library_giving_no_provider_is_an_error() {
        let none: *mut *const QnnInterface_t = ptr::null_mut();
        // SAFETY: a null array, and an array of one null provider.
        let (no_array, null_provider) = unsafe {
            (
                offered("libQnnHtp.so", none, 0).map(|providers| providers.len()),
                offered("libQnnHtp.so", [ptr::null()].as_mut_ptr(), 1)
                    .map(|providers: Vec<&QnnInterface_t>| providers.len()),
            )
        };
        let message = "libQnnHtp.so gave no interface provider".to_string();
        assert_eq!(no_array, Err(message.clone()));
        assert_eq!(null_provider, Err(message));
    }

    #[test]
    fn a_graph_without_a_name_is_an_error() {
        // SAFETY: both structs are plain data whose zero is a null pointer or a zero count.
        let (mut graph, mut info): (QnnSystemContext_GraphInfo_t, QnnSystemContext_BinaryInfo_t) =
            unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
        graph.version = QNN_SYSTEM_CONTEXT_GRAPH_INFO_VERSION_1;
        info.version = QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_1;
        info.__bindgen_anon_1.contextBinaryInfoV1.numGraphs = 1;
        info.__bindgen_anon_1.contextBinaryInfoV1.graphs = &mut graph;
        // SAFETY: `info` describes one graph, without a name or tensors.
        let described = unsafe { first_graph(&info) }.map(|(name, _, _)| name);
        assert_eq!(
            described,
            Err("the context binary's first graph has no name".to_string())
        );
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
