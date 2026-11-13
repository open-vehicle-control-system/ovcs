defmodule VisionApi.Application do
  @moduledoc """
  Serves the vision dashboard: its build from `priv/static`, the `/api`
  JSON:API resources and the status and preview channels, all fed by
  `vision_core`.

  An endpoint with `https:` options serves HTTPS with the certificate and
  key they name, generated first when missing
  (`VisionApi.SelfSignedCertificate`). With `:https_redirect_ports`, plain
  HTTP on each of those ports is redirected to it
  (`VisionApiWeb.HttpsRedirect`).
  """

  use Application

  alias VisionApi.SelfSignedCertificate
  alias VisionApiWeb.HttpsRedirect

  @impl Application
  def start(_type, _args) do
    endpoint = Application.get_env(:vision_api, VisionApiWeb.Endpoint, [])
    SelfSignedCertificate.ensure!(endpoint[:https], hostnames())

    children =
      [
        {Phoenix.PubSub, name: VisionApi.PubSub},
        VisionApiWeb.Endpoint
      ] ++
        HttpsRedirect.listeners(
          endpoint[:https],
          Application.get_env(:vision_api, :https_redirect_ports, [])
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: VisionApi.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    VisionApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # The names a browser reaches the unit by: its hostname, and that name over mDNS.
  defp hostnames do
    {:ok, hostname} = :inet.gethostname()
    [to_string(hostname), "#{hostname}.local"]
  end
end
