//! The names of the graphs a DLC holds, which a context binary is generated for.

use std::ffi::{CStr, CString};
use std::ptr;

use libloading::Library;

use crate::ffi::*;
use crate::interface::system_interface;
use crate::{check, missing};

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
