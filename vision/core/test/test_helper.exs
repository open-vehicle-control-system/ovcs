# The :gpu tests need an OpenCL device, which CI runners do not have.
gpu_tests = if Evision.OCL.haveOpenCL() and Evision.OCL.useOpenCL(), do: [], else: [:gpu]
# The :rust tests build and run the Rust workspace; run them with `--only rust`.
ExUnit.start(exclude: [:rust | gpu_tests])
