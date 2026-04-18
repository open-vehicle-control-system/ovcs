defmodule OvcsVehicle.Scaffold do
  @moduledoc """
  Generates a new vehicle package from the template bundled in this
  library's `priv/templates/vehicle/` directory.

  The template is a full VMS + infotainment example. New vehicles
  start from a working setup and prune what they don't need rather
  than building up from nothing. Users don't need any existing
  vehicle checked out — the template is self-contained here.

  Template **contents** are rendered with EEx against these assigns:

      @module  — CamelCase module prefix (e.g. "Ovcs1")
      @name    — snake_case app/dir name (e.g. "ovcs1")
      @upper   — UPPER_CASE display name (e.g. "OVCS1")

  Template **path components** use a literal `{{name}}` marker instead
  of EEx (EEx in filenames is awkward); `{{name}}` is substituted with
  the snake_case name as files are copied.

  File writes go through `Mix.Generator.create_file/3`, giving Rails-
  generator-style coloured output and an interactive conflict prompt
  when a target file already exists.
  """

  require Mix.Generator

  @type assigns :: [module: String.t(), name: String.t(), upper: String.t()]

  @doc """
  Returns the bundled template directory, resolved either from the
  loaded application's priv dir (mix context) or from the repo checkout
  (escript context — priv/ isn't packaged into escripts).
  """
  @spec template_dir(Path.t() | nil) :: Path.t()
  def template_dir(repo_root \\ nil) do
    case repo_root do
      nil ->
        case :code.priv_dir(:ovcs_vehicle) do
          {:error, _} -> raise "ovcs_vehicle priv dir unavailable; pass repo_root"
          priv -> Path.join(priv, "templates/vehicle")
        end

      root ->
        Path.join([root, "libraries/ovcs_vehicle/priv/templates/vehicle"])
    end
  end

  @doc """
  Render the bundled template into `target_dir`.

  Options:
    * `:repo_root` — fallback source location when running from an escript.
    * `:force` — passed through to `Mix.Generator.create_file/3`; `true`
      overwrites without prompting.
  """
  @spec generate(Path.t(), assigns(), keyword()) ::
          :ok | {:error, {:template_missing, Path.t()}}
  def generate(target_dir, assigns, opts \\ []) do
    source = template_dir(Keyword.get(opts, :repo_root))
    create_opts = Keyword.take(opts, [:force])

    if File.dir?(source) do
      File.mkdir_p!(target_dir)
      copy_tree(source, source, target_dir, assigns, create_opts)
      copy_firmware(target_dir, assigns, opts)
      :ok
    else
      {:error, {:template_missing, source}}
    end
  end

  @doc """
  Absolute path to the shared firmware defaults for a given side
  (`:vms` or `:infotainment`) and Nerves target. Layout:

      <repo>/vms/firmware/targets/<target>/
      <repo>/infotainment/firmware/targets/<target>/

  Used by `generate/3` and by the CLI to warn on unknown targets.
  """
  @spec firmware_defaults_dir(Path.t(), :vms | :infotainment, String.t()) :: Path.t()
  def firmware_defaults_dir(repo_root, side, target) do
    Path.join([repo_root, firmware_app(side), "targets", target])
  end

  defp firmware_app(:vms), do: "vms/firmware"
  defp firmware_app(:infotainment), do: "infotainment/firmware"

  # Copy the shared firmware defaults (fwup.conf, config.txt, …) for
  # each enabled side into the scaffolded vehicle's
  # priv/firmware/<side>/. Plain file copies (no EEx) so users can
  # edit in place without touching the shared defaults.
  defp copy_firmware(target_dir, assigns, opts) do
    repo_root = Keyword.get(opts, :repo_root) || raise "repo_root is required for firmware copy"
    create_opts = Keyword.take(opts, [:force])

    copy_firmware_side(target_dir, repo_root, :vms,
      Keyword.fetch!(assigns, :vms_target), create_opts)

    if Keyword.get(assigns, :infotainment, true) do
      case Keyword.get(assigns, :infotainment_target) do
        nil -> :ok
        target ->
          copy_firmware_side(target_dir, repo_root, :infotainment, target, create_opts)
      end
    end
  end

  defp copy_firmware_side(target_dir, repo_root, side, target, create_opts) do
    source = firmware_defaults_dir(repo_root, side, target)

    if File.dir?(source) do
      dst_dir = Path.join([target_dir, "priv/firmware", to_string(side)])

      Enum.each(File.ls!(source), fn file ->
        Mix.Generator.copy_file(
          Path.join(source, file),
          Path.join(dst_dir, file),
          create_opts
        )
      end)
    end
  end

  defp copy_tree(root, dir, target_root, assigns, create_opts) do
    Enum.each(File.ls!(dir), fn entry ->
      src = Path.join(dir, entry)

      cond do
        File.dir?(src) ->
          copy_tree(root, src, target_root, assigns, create_opts)

        skip?(src, root, assigns) ->
          :ok

        true ->
          rel = src |> Path.relative_to(root) |> rename_path(assigns)
          dst = Path.join(target_root, rel)
          Mix.Generator.copy_template(src, dst, assigns, create_opts)
      end
    end)
  end

  defp rename_path(rel, assigns) do
    String.replace(rel, "{{name}}", Keyword.fetch!(assigns, :name))
  end

  # Skip paths that belong to a side the caller disabled. Infotainment
  # files live under any path component starting with "infotainment"
  # (e.g. `lib/{{name}}/infotainment.ex`, `lib/{{name}}/infotainment/…`,
  # `priv/can/infotainment.yml`).
  defp skip?(src, root, assigns) do
    if Keyword.get(assigns, :infotainment, true) do
      false
    else
      src
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.any?(&String.starts_with?(&1, "infotainment"))
    end
  end
end
