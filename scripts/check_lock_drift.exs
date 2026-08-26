#!/usr/bin/env elixir
#
# Fails when a shared *dev-tooling* dependency is locked at different
# versions across the repo's Mix projects.
#
# Why an allowlist rather than every dep: the locks legitimately
# diverge. Nerves system deps differ per target by design, and
# transitive versions follow whatever each project's own constraints
# resolve to. A check over all deps would fail on day one and get
# deleted. Dev tooling is different — every project runs the same
# `mix credo` against the same root .credo.exs, so a project sitting on
# an older credo is drift, not a design choice.
#
# The concrete failure this exists to prevent: vms/core sat on credo
# 1.7.8 while everything else was on 1.7.18, and it only surfaced as
# `Regex.CompileError: invalid range in character class` when the
# Elixir version moved — a confusing error a long way from its cause.
#
# Usage: elixir scripts/check_lock_drift.exs

tracked = ~w(credo)

# Ask git rather than globbing: that skips deps/ and _build/, and more
# importantly skips the sideloaded libraries/ clones (cantastic,
# express_lrs, …). Those live in their own repos, so drift there isn't
# something a change here could fix — reporting it would just be noise.
locks =
  case System.cmd("git", ["ls-files", "*mix.lock"]) do
    {out, 0} -> out |> String.split("\n", trim: true) |> Enum.sort()
    {_out, _code} -> []
  end

if locks == [] do
  IO.puts(:stderr, "no tracked mix.lock files found — run from the repo root")
  System.halt(1)
end

# Read the version textually. Evaluating a lock file would be more
# principled, but Elixir emits a quoted-keyword warning for every entry
# in every lock (hundreds of KB of noise), and the hex tuple's shape
# here — "name": {:hex, :name, "version", ... — is stable enough that
# matching it is the lesser evil.
version_in = fn path, dep ->
  pattern = ~r/"#{Regex.escape(dep)}": \{:hex, :#{Regex.escape(dep)}, "([^"]+)"/

  case Regex.run(pattern, File.read!(path)) do
    [_full, version] -> version
    nil -> nil
  end
end

drift =
  Enum.flat_map(tracked, fn dep ->
    found =
      locks
      |> Enum.map(fn path -> {path, version_in.(path, dep)} end)
      |> Enum.reject(fn {_path, version} -> is_nil(version) end)

    versions = found |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    IO.puts("#{dep}: #{length(found)} projects, #{length(versions)} distinct version(s)")

    Enum.each(found, fn {path, version} ->
      IO.puts("  #{String.pad_trailing(version, 10)} #{path}")
    end)

    if length(versions) > 1, do: [{dep, found, versions}], else: []
  end)

if drift == [] do
  IO.puts("\nno dev-tooling lock drift")
  System.halt(0)
end

IO.puts(:stderr, "\nlock drift detected:")

Enum.each(drift, fn {dep, found, versions} ->
  # Name the minority side — that's what needs `mix deps.update <dep>`.
  majority =
    found
    |> Enum.frequencies_by(&elem(&1, 1))
    |> Enum.max_by(&elem(&1, 1))
    |> elem(0)

  behind = Enum.reject(found, fn {_path, version} -> version == majority end)

  IO.puts(:stderr, "  #{dep}: #{Enum.join(versions, ", ")} (most projects on #{majority})")

  Enum.each(behind, fn {path, version} ->
    project = Path.dirname(path)
    IO.puts(:stderr, "    #{project} is on #{version} — run: cd #{project} && mix deps.update #{dep}")
  end)
end)

System.halt(1)
