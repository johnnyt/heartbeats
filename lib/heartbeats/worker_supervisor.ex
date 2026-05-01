defmodule Heartbeats.WorkerSupervisor do
  @moduledoc """
  Local `DynamicSupervisor` that owns the heartbeat workers running on this node.

  Workers are started through `Heartbeats.Placement.place/1`, which decides
  via the ring whether the worker belongs here or on another node and routes
  the start request via RPC if needed.
  """

  use DynamicSupervisor

  alias Heartbeats.{Subscription, Worker}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts a `Heartbeats.Worker` for `subscription` under this node's supervisor.

  Returns `{:ok, pid}` for both newly-started and already-running workers (the
  Registry uniqueness ensures only one worker per subscription id per node).
  """
  @spec start_worker(Subscription.t()) :: DynamicSupervisor.on_start_child()
  def start_worker(%Subscription{} = subscription) do
    spec = %{
      id: Worker,
      start: {Worker, :start_link, [subscription]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end
end
