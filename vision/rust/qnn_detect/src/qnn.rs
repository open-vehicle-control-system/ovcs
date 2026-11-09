//! A QNN context binary run on the HTP backend, through QAIRT's shared
//! libraries loaded at run time from the library path.

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

use std::ffi::{c_void, CStr};
use std::ptr;

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
    pub bytes: usize,
    raw: Qnn_Tensor_t,
}

/// A context binary's first graph, ready to execute.
pub struct Model {
    interface: QnnInterface_ImplementationV2_39_t,
    graph: Qnn_GraphHandle_t,
    pub inputs: Vec<Tensor>,
    pub outputs: Vec<Tensor>,
    // The handles and the libraries live as long as the process.
    _backend: Qnn_BackendHandle_t,
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

            Ok(Model {
                interface,
                graph,
                inputs,
                outputs,
                _backend: backend,
                _context: context,
                _libraries: [backend_library, system_library],
            })
        }
    }

    /// Runs the graph on `inputs`, filling `outputs`, each the size of its tensor.
    pub fn execute(
        &self,
        inputs: &mut [&mut [u8]],
        outputs: &mut [&mut [u8]],
    ) -> Result<(), String> {
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
        unsafe {
            check(
                "graphExecute",
                self.interface
                    .graphExecute
                    .ok_or_else(|| missing("graphExecute"))?(
                    self.graph,
                    inputs.as_ptr(),
                    inputs.len() as u32,
                    outputs.as_mut_ptr(),
                    outputs.len() as u32,
                    ptr::null_mut(),
                    ptr::null_mut(),
                ),
            )
        }
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
}
