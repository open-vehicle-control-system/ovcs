defmodule VisionApiWeb.TestUnit do
  @moduledoc """
  A vision unit of the test's own: `start/1` restarts `:vision_core` on
  a configuration, and back to none once the test is over.
  """
  @behaviour VisionCore.Composer

  @impl VisionCore.Composer
  def config(_arm), do: Application.fetch_env!(:vision_core, :test_config)

  @doc "Restarts `:vision_core` on `config` for the calling test."
  @spec start(VisionCore.Config.t()) :: :ok
  def start(%VisionCore.Config{} = config) do
    Application.stop(:vision_core)
    Application.put_env(:vision_core, :test_config, config)
    Application.put_env(:vision_core, :vehicle, __MODULE__)
    {:ok, _apps} = Application.ensure_all_started(:vision_core)

    ExUnit.Callbacks.on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.delete_env(:vision_core, :test_config)
      Application.ensure_all_started(:vision_core)
    end)

    :ok
  end
end
