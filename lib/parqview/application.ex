defmodule Parqview.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ParqviewWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:parqview, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Parqview.PubSub},
      # Start a worker by calling: Parqview.Worker.start_link(arg)
      # {Parqview.Worker, arg},
      # Start to serve requests, typically the last entry
      ParqviewWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Parqview.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ParqviewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
