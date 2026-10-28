fn main() {
    if std::env::var_os("CARGO_FEATURE_DEVICE").is_some() {
        pkg_config::probe_library("libturbojpeg").expect("libturbojpeg not found by pkg-config");
    }
}
