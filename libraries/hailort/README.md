# Hailort

[HailoRT](https://github.com/hailo-ai/hailort)'s `libhailort`, built from source for Nerves targets, for native code that drives a Hailo-8.

## What it builds

On a Nerves target, `mix compile` downloads the HailoRT source release (pinned by sha256, cached in `NERVES_DL_DIR`, `~/.nerves/dl` by default) and cross-compiles only `libhailort` with CMake and the Nerves toolchain. protobuf-lite, spdlog and HailoRT's other externals are linked statically, so the library needs nothing from the system beyond libc, libstdc++ and libatomic. The CLI, service, GStreamer plugin, Python bindings and tests are not built.

The externals HailoRT's CMake would clone at configure time are downloaded by the `Makefile` instead, as tarballs pinned by sha256 at the commits HailoRT pins, and CMake runs disconnected. Every download is cached next to the HailoRT tarball, so only the first build needs network access. HailoRT also builds a host `protoc` for its protobuf sources, which needs a host C++ compiler.

| Output | Path | In the firmware |
|--------|------|-----------------|
| `libhailort.so.<version>` | `Hailort.lib_dir/0` (`priv/lib`) | yes |
| `libhailort.so`, the link-time symlink | `Hailort.link_dir/0` (`native/lib` in the app build dir) | no |
| `hailo/*.h`, `hailo/*.hpp` | `Hailort.include_dir/0` (`native/include` in the app build dir) | no |

On the host nothing is built, so applications that depend on it still compile and test there.

## Using it

A dependent Makefile run by `elixir_make` finds the outputs under `$(MIX_BUILD_PATH)/lib/hailort/`: compile with `-I.../native/include`, link with `-L.../native/lib -lhailort`. At runtime, start the executable with `LD_LIBRARY_PATH` set to `Hailort.lib_dir()`. `RosBridge.Inference.Hailo` and `bridges/ros_bridge/c_src/hailo_detect` are the worked example.

## Version coupling

`libhailort` talks to the `hailo_pci` kernel driver, and the two must be the same HailoRT release. The Nerves system ships the driver and its firmware; this library's version (`mix.exs` and the `Makefile`) follows it. Bumping one means bumping the other, and re-pinning the externals in the `Makefile` against the new release's `hailort/cmake/external/*.cmake`.

## License

HailoRT is MIT-licensed (`hailort/LICENSE` in the source release); its third-party components are listed in `hailort/LICENSE-3RD-PARTY.md`.
