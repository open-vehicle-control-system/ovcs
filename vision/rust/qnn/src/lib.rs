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

mod dlc;
mod interface;
pub mod port;
mod power;
mod profile;
mod stage_times;
mod tensor;
mod time_log;

pub use dlc::{dlc_graph_names, print_dlc_graph_names};
pub use power::{command_line, CommandLine, Performance, Power, DEFAULT_PERFORMANCE};
pub use profile::{ProfiledTimes, TimeSource, Timing, EXECUTION_STAGES};
pub use stage_times::{micros, Stage, StageTimes, STAGE_TIMES_EVERY};
pub use tensor::{Quantisation, Tensor};
pub use time_log::TimeLog;

use std::ffi::{c_void, CStr};
use std::ptr;
use std::time::Instant;

use ffi::*;
use interface::{backend_interface, system_interface};
use libloading::Library;
use power::{vote, PowerVote};
use profile::{
    collect_events, create_profile, top_level_events, EventCursor, Profile, ProfileEvent,
    EXECUTIONS_PER_PROFILE,
};
use tensor::{bind, Tensors};

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
                Tensors::from_raw($v.graphInputs, $v.numGraphInputs)?,
                Tensors::from_raw($v.graphOutputs, $v.numGraphOutputs)?,
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
    unsafe fn binary_info(
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
        let info = unsafe { session.binary_info(binary) }?;
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
        let (inference_micros, source) = match profiled.accelerator_micros {
            Some(micros) => (micros, TimeSource::Accelerator),
            None => (graph_execute_micros, TimeSource::WallTime),
        };
        Ok(Timing {
            inference_micros,
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
