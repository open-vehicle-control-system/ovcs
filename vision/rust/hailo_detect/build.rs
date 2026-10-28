fn main() {
    #[cfg(feature = "device")]
    hailort();
}

#[cfg(feature = "device")]
fn hailort() {
    // libhailort comes from the :hailort dependency, which has no pkg-config file.
    println!("cargo:rerun-if-env-changed=HAILORT_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=HAILORT_LINK_DIR");
    let include_dir = std::env::var("HAILORT_INCLUDE_DIR").expect("HAILORT_INCLUDE_DIR is unset");
    let link_dir = std::env::var("HAILORT_LINK_DIR").expect("HAILORT_LINK_DIR is unset");
    println!("cargo:rustc-link-search=native={link_dir}");
    println!("cargo:rustc-link-lib=dylib=hailort");

    let bindings = bindgen::Builder::default()
        .clang_arg(format!("-I{include_dir}"))
        .header_contents("wrapper.h", "#include <hailo/hailort.h>\n")
        .allowlist_function("hailo_.*")
        .allowlist_type("hailo_.*")
        .allowlist_var("HAILO_.*")
        .prepend_enum_name(false)
        .layout_tests(false)
        .generate()
        .expect("bindgen failed on hailo/hailort.h");

    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("hailort.rs");
    bindings
        .write_to_file(out)
        .expect("could not write hailort.rs");
}
