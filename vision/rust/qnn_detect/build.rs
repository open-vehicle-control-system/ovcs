// QNN's headers are proprietary: the bindings are generated from the QAIRT
// archive at build time, never committed.
fn main() {
    println!("cargo:rerun-if-env-changed=QAIRT_INCLUDE_DIR");
    let include_dir = std::env::var("QAIRT_INCLUDE_DIR").unwrap_or_else(|_| {
        panic!(
            "QAIRT_INCLUDE_DIR is unset: it names QAIRT's include/QNN directory, which \
             `mise run fetch-qairt` caches in the QAIRT archive"
        )
    });

    let bindings = bindgen::Builder::default()
        .clang_arg(format!("-I{include_dir}"))
        .header_contents(
            "wrapper.h",
            "#include <QnnInterface.h>\n#include <System/QnnSystemInterface.h>\n",
        )
        .allowlist_type("Qnn.*")
        .allowlist_var("QNN_.*")
        .prepend_enum_name(false)
        .layout_tests(false)
        .generate()
        .expect("bindgen failed on the QNN headers");

    let path = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("qnn.rs");
    bindings
        .write_to_file(path)
        .expect("could not write qnn.rs");
}
