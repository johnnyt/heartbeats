defmodule Heartbeats.Placement do
  @moduledoc """
  Per-node GenServer that decides where heartbeat workers run and serves as
  the RPC entry point for placement requests from other nodes.

  When `place/1` is called locally:
    - Looks up `Ring.owner(sub.id)`.
    - If the owner is this node, starts the worker via `WorkerSupervisor`.
    - Otherwise, RPCs the same `place/1` request to the owner via
      `GenServer.call({Placement, owner_node}, ...)`.

  Auto-rebalancing on `:nodeup` / `:nodedown` lands in Phase 3.
  """

  use GenServer

  alias Heartbeats.{Ring, Subscription, Subscriptions, Worker, WorkerSupervisor}

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures a worker is running on the ring-determined owner node for `subscription`.

  Returns `{:ok, pid}` (pid is on the owner node, may be remote) or
  `{:error, :unschedulable}` if the ring has no members.
  """
  @spec place(Subscription.t()) :: {:ok, pid()} | {:error, term()}
  def place(%Subscription{} = subscription) do
    case Ring.owner(subscription.id) do
      {:error, {:invalid_ring, :no_nodes}} ->
        {:error, :unschedulable}

      node when node == node() ->
        WorkerSupervisor.start_worker(subscription)

      remote_node ->
        GenServer.call({__MODULE__, remote_node}, {:place, subscription})
    end
  end

  @doc """
  Stops the worker for `subscription_id` wherever it currently runs.

  Best-effort: if the ring no longer maps the id (e.g. ring empty), this is
  a no-op.
  """
  @spec unplace(String.t()) :: :ok
  def unplace(subscription_id) when is_binary(subscription_id) do
    case Ring.owner(subscription_id) do
      {:error, {:invalid_ring, :no_nodes}} ->
        :ok

      node when node == node() ->
        stop_local_worker(subscription_id)

      remote_node ->
        GenServer.call({__MODULE__, remote_node}, {:unplace, subscription_id})
    end
  end

  @doc """
  Sends `:rebalance` to every worker currently running on this node.

  Each worker recomputes its ring owner; if the owner is no longer this node
  it migrates itself to the new owner before stopping.
  """
  @spec rebalance_local() :: :ok
  def rebalance_local do
    GenServer.cast(__MODULE__, :rebalance_local)
  end

  @doc "Returns local placement stats for the dashboard / health checks."
  @spec stats() :: %{worker_count: non_neg_integer(), node: node()}
  def stats do
    %{
      worker_count: DynamicSupervisor.count_children(WorkerSupervisor).active,
      node: Node.self()
    }
  end

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:place, %Subscription{} = sub}, _from, state) do
    {:reply, WorkerSupervisor.start_worker(sub), state}
  end

  def handle_call({:unplace, id}, _from, state) when is_binary(id) do
    stop_local_worker(id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:rebalance_local, state) do
    for sub <- Subscriptions.all() do
      case Worker.whereis(sub.id) do
        pid when is_pid(pid) -> send(pid, :rebalance)
        nil -> :ok
      end
    end

    {:noreply, state}
  end

  ## Helpers

  defp stop_local_worker(subscription_id) do
    case Worker.whereis(subscription_id) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, pid)

      nil ->
        :ok
    end
  end
end
