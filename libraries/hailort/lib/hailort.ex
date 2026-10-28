defmodule Hailort do
  @moduledoc """
  HailoRT's `libhailort`, built from source for the Nerves target.

  Native code that drives a Hailo device compiles against `include_dir/0`
  and links `-lhailort` from `link_dir/0`. At runtime the dynamic loader
  finds the library through `LD_LIBRARY_PATH` set to `lib_dir/0`. On the
  host nothing is built and the three directories are absent.
  """

  @doc "Directory holding `libhailort.so.<version>`, shipped in the firmware."
  @spec lib_dir() :: String.t()
  def lib_dir, do: Application.app_dir(:hailort, "priv/lib")

  @doc """
  Directory holding the `hailo/` headers. Present only in the build tree,
  not in the firmware.
  """
  @spec include_dir() :: String.t()
  def include_dir, do: Application.app_dir(:hailort, "native/include")

  @doc """
  Directory holding the `libhailort.so` link-time symlink. Present only in
  the build tree, not in the firmware.
  """
  @spec link_dir() :: String.t()
  def link_dir, do: Application.app_dir(:hailort, "native/lib")
end
