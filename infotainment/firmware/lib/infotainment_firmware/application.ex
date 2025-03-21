defmodule InfotainmentFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger
  alias NervesFlutterSupport.Udev

  @impl true
  def start(_type, _args) do
    children = [] ++ children(Nerves.Runtime.mix_target())
    opts = [strategy: :one_for_one, name: NervesFlutterExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def start_phase(:load_and_start_apps, _start_type, _args) do
    load_and_start_apps(:infotainment_api)
  end

  def load_and_start_apps(application) do
    case Application.ensure_all_started(application) do
      {:ok, _} ->
        Logger.info("#{application} started successfully!")
      {:error, :nomatch} ->
        Logger.warning("#{application} could not start, continuing without it.")
    end
    :ok
  end

  defp children(:host) do
    []
  end

  defp children(_target) do
    # Bit of a hack, but we need to wait for /dev/dri to exists...
    dri_card = get_output_card()

    launch_env = %{
      "FLUTTER_DRM_DEVICE" => "/dev/dri/#{dri_card}",
      "GALLIUM_HUD" => "cpu+fps",
      "GALLIUM_HUD_PERIOD" => "0.25",
      "GALLIUM_HUD_SCALE" => "3",
      "GALLIUM_HUD_VISIBLE" => "false",
      "GALLIUM_HUD_TOGGLE_SIGNAL" => "10"
    }

    [
      # Create a child that runs the Flutter embedder.
      # The `:app_name` matches this application, since it contains the AOT bundle at `priv/flutter_app`.
      # See the doc annotation for `create_child/1` for all valid options.
      NervesFlutterSupport.Flutter.Engine.create_child(
        app_name: :infotainment_firmware,
        env: launch_env
      )
    ]
  end

  defp get_output_card() do
    Process.sleep(100)
    output = Udev.get_cards() |> Enum.find(fn card -> Udev.is_output_card?(card) end)

    if is_nil(output) do
      get_output_card()
    else
      output
    end
  end
end
