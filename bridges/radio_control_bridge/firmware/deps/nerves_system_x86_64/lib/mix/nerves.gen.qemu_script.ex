defmodule Mix.Tasks.Nerves.Gen.QemuScript do
  use Mix.Task

  @shortdoc "Generate QEMU start script"

  @moduledoc """
  Generates a shell script for starting QEMU on a firmware image that
  uses `nerves_system_x86_64`.

  To use the generated script, first create the firmware image using:

  `$ mix firmware.image [path/to/my_app.img]`

  Place this image somewhere where it won't get overwritten. This image
  has a similar purpose to the MicroSD card, Flash memory or hard drive
  that a real target would use.

  Next, run this command and specify the path to the image. This path
  may be overridden when invoking the script.

  Example usage:

    `$ mix nerves.gen.qemu_script [path/to/my_app.img]`

  If the `.img` file isn't specified, it will default to the OTP
  application's name plus the `.img` extension.

  ## Options

  None
  """

  @script_name "run-qemu.sh"

  def run(["--" <> _arg | _argv]) do
    error_image()
  end

  def run([image_path | _argv]) do
    if File.exists?(@script_name) do
      Mix.shell().yes?("Overwrite #{@script_name}?") || Mix.raise("Aborted")
    end

    source =
      :code.priv_dir(:nerves_system_x86_64)
      |> to_string
      |> Path.join(@script_name)

    bindings = [image_path: image_path]
    contents = EEx.eval_file(source, bindings, trim: true)
    File.write!(@script_name, contents)
    File.chmod!(@script_name, 0o755)

    Mix.shell().info("Created #{@script_name}")
  end

  def run([]) do
    otp_app = Mix.Project.config()[:app]
    image_path = "#{otp_app}.img"
    run([image_path])
  end

  def run(_), do: error_image()

  defp error_image do
    Mix.raise("""
      Unexpected arguments. Expecting to be run as follows:

      $ mix nerves.gen.qemu_script [path/to/app.img]
    """)
  end
end
