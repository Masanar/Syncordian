defmodule Syncordian.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    :ets.new(:session, [:named_table, :public, read_concurrency: true])
    children = [
      SyncordianWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:syncordian, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Syncordian.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Syncordian.Finch},
      # Start a worker by calling: Syncordian.Worker.start_link(arg)
      # {Syncordian.Worker, arg},
      # Start to serve requests, typically the last entry
      SyncordianWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Syncordian.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SyncordianWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
