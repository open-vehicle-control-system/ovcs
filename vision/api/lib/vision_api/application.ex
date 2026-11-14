defmodule VisionApi.Application do
  @moduledoc """
  Serves the vision dashboard: its build from `priv/static`, the `/api`
  JSON:API resources and the status and preview channels, all fed by
  `vision_core`.

  An endpoint with `https:` options serves HTTPS with the certificate and
  key they name, generated first when they hold no pair for the unit's
  names, and with a pair held in memory when they cannot be written
  (`VisionApi.SelfSignedCertificate`). With `:https_redirect_ports`, plain
  HTTP on each of those ports is redirected to it
  (`VisionApiWeb.HttpsRedirect`); an endpoint without `https:` listens on
  none of them.
  """

  use Application

  alias VisionApi.SelfSignedCertificate
  alias VisionApiWeb.HttpsRedirect

  @impl Application
  def start(_type, _args) do
    endpoint = Application.get_env(:vision_api, VisionApiWeb.Endpoint, [])
    https = SelfSignedCertificate.https_options(endpoint[:https], hostnames())

    if https != endpoint[:https],
      do:
        Application.put_env(
          :vision_api,
          VisionApiWeb.Endpoint,
          Keyword.put(endpoint, :https, https)
        )

    children =
      [
        {Phoenix.PubSub, name: VisionApi.PubSub},
        VisionApiWeb.Endpoint
      ] ++
        HttpsRedirect.listeners(
          https,
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
