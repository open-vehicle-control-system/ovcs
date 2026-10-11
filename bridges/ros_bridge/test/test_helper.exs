# The :gpu tests need an OpenCL device, which CI runners do not have.
gpu_tests = if Evision.OCL.haveOpenCL() and Evision.OCL.useOpenCL(), do: [], else: [:gpu]
ExUnit.start(exclude: gpu_tests)
