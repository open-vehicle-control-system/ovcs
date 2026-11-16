//! The interfaces of QNN's HTP backend and system libraries, of the API versions the build
//! reads.

use std::ptr;

use libloading::Library;

use crate::check;
use crate::ffi::*;

type GetProviders =
    unsafe extern "C" fn(*mut *mut *const QnnInterface_t, *mut u32) -> Qnn_ErrorHandle_t;

type GetSystemProviders =
    unsafe extern "C" fn(*mut *mut *const QnnSystemInterface_t, *mut u32) -> Qnn_ErrorHandle_t;

/// The interface of `libQnnHtp.so` of this QNN API version.
///
/// # Safety
/// `library` is `libQnnHtp.so`, and the interface is used only while it stays loaded.
pub(crate) unsafe fn backend_interface(
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
pub(crate) unsafe fn system_interface(
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
}
