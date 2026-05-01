defmodule Heartbeats.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        HeartbeatsWeb.Telemetry,
        {Phoenix.PubSub, name: Heartbeats.PubSub}
      ] ++
        cluster_children() ++
        [
          {Registry, keys: :unique, name: Heartbeats.Registry},
          Heartbeats.Subscriptions,
          Heartbeats.WorkerSupervisor,
          Heartbeats.Placement,
          HeartbeatsWeb.Endpoint,
          Heartbeats.GracefulShutdown
        ]

    opts = [strategy: :one_for_one, name: Heartbeats.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HeartbeatsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp cluster_children do
    enabled = Application.get_env(:heartbeats, :clustering_enabled, true)

    if should_cluster?(enabled, Node.self()) do
      [{Cluster.Supervisor, [topology(), [name: Heartbeats.ClusterSupervisor]]}]
    else
      []
    end
  end

  # `:nonode@nohost` means the BEAM was started without a name
  # (e.g. `iex -S mix` rather than `iex --name a@127.0.0.1 -S mix`).
  # `Cluster.Strategy.LocalEpmd` requires a named node, so skip clustering.
  defp should_cluster?(_enabled, :nonode@nohost), do: false
  defp should_cluster?(enabled, _node_name), do: enabled

  defp topology do
    [local: [strategy: Cluster.Strategy.LocalEpmd]]
  end
end
