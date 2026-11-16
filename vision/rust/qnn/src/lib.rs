//! A QNN context binary run on the HTP backend, through QAIRT's shared
//! libraries loaded at run time from the library path. Each execution is timed
//! by QNN's basic profiling, the HTP's own execution time, or by the wall time
//! around `graphExecute` when the profile is unavailable; `TimeLog` says which.
//! The HTP runs under a power vote (`Power`): a performance profile's clocks and the RPC
//! polling.

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
mod profile;
mod stage_times;
mod tensor;
mod time_log;

pub use performance::{command_line, CommandLine, Performance, Power, DEFAULT_PERFORMANCE};
pub use profile::{ProfiledTimes, TimeSource, Timing, EXECUTION_STAGES};
pub use stage_times::{micros, Stage, StageTimes, STAGE_TIMES_EVERY};
pub use tensor::Tensor;
pub use time_log::TimeLog;

use std::ffi::{c_void, CStr, CString};
use std::ptr;
use std::time::Instant;

use ffi::*;
use libloading::Library;
use profile::{
    collect_events, create_profile, top_level_events, EventCursor, Profile, ProfileEvent,
    EXECUTIONS_PER_PROFILE,
};
use tensor::{bind, describe_all, Tensors};

type GetProviders =
    unsafe extern "C" fn(*mut *mut *const QnnInterface_t, *mut u32) -> Qnn_ErrorHandle_t;
type GetSystemProviders =
    unsafe extern "C" fn(*mut *mut *const QnnSystemInterface_t, *mut u32) -> Qnn_ErrorHandle_t;

/// A context binary's first graph, ready to execute.
pub struct Model {
    session: Session,
    graph: Qnn_GraphHandle_t,
    pub graph_name: String,
    pub inputs: Vec<Tensor>,
    pub outputs: Vec<Tensor>,
    // QNN's tensors point into the session's system context, valid as long as `session`, and
    // at the latest execution's buffers, valid only during it.
    raw_inputs: Vec<Qnn_Tensor_t>,
    raw_outputs: Vec<Qnn_Tensor_t>,
    /// Why executions are timed by the wall time, once the profile is unavailable.
    pub profile_error: Option<String>,
    /// The first profiled execution's events, until `take_profile_report`.
    profile_report: Option<String>,
    profile_reported: bool,
    /// Why the power vote is missing or partial, if it is.
    pub power_vote_error: Option<String>,
    /// The latest execution's top-level event ids and events, kept between executions.
    event_ids: Vec<QnnProfile_EventId_t>,
    events: Vec<ProfileEvent>,
}

/// The QNN libraries and what a model creates in them, each handle null until it is created.
/// Dropped, it frees them, the latest created first, before the libraries unload.
struct Session {
    interface: QnnInterface_ImplementationV2_39_t,
    system: QnnSystemInterface_ImplementationV1_14_t,
    system_context: QnnSystemContext_Handle_t,
    backend: Qnn_BackendHandle_t,
    device: Qnn_DeviceHandle_t,
    power_vote: Option<PowerVote>,
    context: Qnn_ContextHandle_t,
    profile: Option<Profile>,
    _libraries: [Library; 2],
}

impl Drop for Session {
    fn drop(&mut self) {
        let (interface, system) = (&self.interface, &self.system);
        // SAFETY: each handle is null or one these libraries created and nothing has freed,
        // and the libraries unload only after this, with the fields.
        unsafe {
            if let (Some(profile), Some(free)) = (self.profile.take(), interface.profileFree) {
                free(profile.handle);
            }
            if let (false, Some(free)) = (self.context.is_null(), interface.contextFree) {
                free(self.context, ptr::null_mut());
            }
            // The vote is the device's infrastructure's.
            drop(self.power_vote.take());
            if let (false, Some(free)) = (self.device.is_null(), interface.deviceFree) {
                free(self.device);
            }
            if let (false, Some(free)) = (self.backend.is_null(), interface.backendFree) {
                free(self.backend);
            }
            if let (false, Some(free)) = (self.system_context.is_null(), system.systemContextFree) {
                free(self.system_context);
            }
        }
    }
}

/// A power config id holding a power vote, which ends when it is destroyed.
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

/// The calls of a power vote, in `Power::power_configs`' order.
const POWER_CONFIG_CALLS: [&str; 3] = [
    "setPowerConfig DCVS_V3",
    "setPowerConfig RPC_CONTROL_LATENCY",
    "setPowerConfig RPC_POLLING_TIME",
];

/// Votes `power` on the HTP through the device's performance infrastructure. The vote
/// holds while the returned id lives; there is none when the DCVS_V3 call fails. The message
/// names each call that failed.
///
/// # Safety
/// `interface` is of a library still loaded, after its `deviceCreate`.
unsafe fn vote(
    interface: &QnnInterface_ImplementationV2_39_t,
    power: Power,
) -> (Option<PowerVote>, Option<String>) {
    let unvoted = |message: String| {
        (
            None,
            Some(format!(
                "{message}; the HTP runs under its default power policy"
            )),
        )
    };
    if power.performance == Performance::NoVote {
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
    for (config, call) in power.power_configs(id).iter().zip(POWER_CONFIG_CALLS) {
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
    /// Loads the HTP backend, votes `power` on it, and creates the context `binary`
    /// holds. A vote that fails leaves the HTP under its default power policy, the reason in
    /// `power_vote_error`.
    pub fn open(binary: &[u8], power: Power) -> Result<Model, String> {
        // SAFETY: loading runs the libraries' initialisers, which ask nothing of the caller.
        let mut session = unsafe { Session::load() }?;
        // SAFETY: called once, on the session just loaded.
        let info = unsafe { session.describe_binary(binary) }?;
        // SAFETY: `info` is null or the description the session's system context holds until
        // the session is dropped, with the model.
        let info =
            unsafe { info.as_ref() }.ok_or("systemContextGetBinaryInfo gave no description")?;
        // SAFETY: `info` is a description the session's system context gave and still holds.
        let (graph_name, inputs, outputs) = unsafe { first_graph(info) }?;
        // SAFETY: `first_graph` refuses a null name; the name is NUL-terminated, and the system
        // context holds it.
        let graph_name_text = unsafe { CStr::from_ptr(graph_name) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: called once, on a session without a backend.
        unsafe { session.create_backend() }?;
        // SAFETY: the session keeps the backend's library loaded, and `create_backend` called its
        // `deviceCreate` where it has one.
        let (power_vote, power_vote_error) = unsafe { vote(&session.interface, power) };
        session.power_vote = power_vote;
        // SAFETY: called once, after `create_backend`.
        unsafe { session.create_context(binary) }?;
        // SAFETY: called after `create_context`, on the NUL-terminated name the system context
        // holds.
        let graph = unsafe { session.retrieve_graph(graph_name) }?;
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
            event_ids: Vec::new(),
            events: Vec::new(),
        })
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
        inputs: &mut [impl AsMut<[u8]>],
        outputs: &mut [impl AsMut<[u8]>],
    ) -> Result<Timing, String> {
        bind("input", &self.inputs, &mut self.raw_inputs, inputs)?;
        bind("output", &self.outputs, &mut self.raw_outputs, outputs)?;
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
        // description, just bound to a buffer of its size that outlives the call.
        let executed = check("graphExecute", unsafe {
            graph_execute(
                self.graph,
                self.raw_inputs.as_ptr(),
                self.raw_inputs.len() as u32,
                self.raw_outputs.as_mut_ptr(),
                self.raw_outputs.len() as u32,
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
        let Some(profile) = self.session.profile.as_mut() else {
            return ProfiledTimes::default();
        };
        let interface = &self.session.interface;
        // SAFETY: the handle is the session's live profile.
        unsafe { top_level_events(interface, profile.handle, &mut self.event_ids) };
        let latest = profile.cursor.latest_execution(self.event_ids.len());
        let replace = latest.is_none() || profile.cursor.executions >= EXECUTIONS_PER_PROFILE;
        self.events.clear();
        for &id in &self.event_ids[latest.unwrap_or_default()] {
            // SAFETY: the profile that gave `id` is still alive.
            unsafe { collect_events(interface, id, &mut self.events) };
        }
        if !self.profile_reported && !self.events.is_empty() {
            self.profile_reported = true;
            self.profile_report = Some(format!(
                "{:?}",
                self.events
                    .iter()
                    .map(|event| (event.kind, event.unit, event.value))
                    .collect::<Vec<_>>()
            ));
        }
        if replace {
            self.replace_profile();
        }
        ProfiledTimes::of(&self.events)
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
