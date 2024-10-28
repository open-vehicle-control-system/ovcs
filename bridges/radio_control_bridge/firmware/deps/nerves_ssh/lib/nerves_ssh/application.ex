defmodule NervesSSH.Application do
  @moduledoc false

  use Application

  alias NervesSSH.Options

  if Application.get_all_env(:nerves_ssh) == [] and
       Application.get_all_env(:nerves_firmware_ssh) != [] do
    raise """
    :nerves_ssh isn't configured, but :nerves_firmware_ssh is.

    This is probably not right. If you recently upgraded to :nerves_ssh or
    a library that uses it like :nerves_pack, you'll need to edit your config.exs
    and rename references to :nerves_firmware_ssh to :nerves_ssh. See
    https://hexdocs.pm/nerves_ssh/readme.html#configuration.

    To use both :nerves_ssh and :nerves_firmware_ssh simultaneously, supply a
    :nerves_ssh config to bypass this error.
    """
  end

  @impl Application
  def start(_type, _args) do
    children =
      case Application.get_all_env(:nerves_ssh) do
        [] ->
          # No app environment, so don't start
          []

        app_env ->
          [{NervesSSH, Options.with_defaults(app_env)}]
      end

    opts = [strategy: :one_for_one, name: NervesSSH.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
