# Nx stages on Nx's evaluator take minutes per frame; EXLA compiles them for the CPU.
Application.put_env(:vision_core, :nx_defn_options, compiler: EXLA)

# VisionCore.Jpeg's Port (jpeg_codec), built from the Rust workspace; the :jpeg tests need it.
rust_workspace = Path.expand("../../rust", __DIR__)

jpeg_tests =
  case System.cmd("cargo", ["build", "-q", "--release", "-p", "jpeg_codec"],
         cd: rust_workspace,
         stderr_to_stdout: true
       ) do
    {_output, 0} ->
      Application.put_env(
        :vision_core,
        :jpeg_codec_path,
        Path.join(rust_workspace, "target/release/jpeg_codec")
      )

      []

    {output, _status} ->
      IO.puts("jpeg_codec did not build, skipping the :jpeg tests:\n" <> output)
      [:jpeg]
  end

# The :rust tests build and run the Rust workspace; run them with `--only rust`.
# The :vulkan tests need a Vulkan device, which CI runners do not have, and
# the :iree tests run the IREE compiler; run them with `--include vulkan`
# or `--include iree`.
ExUnit.start(exclude: [:rust, :vulkan, :iree | jpeg_tests])
