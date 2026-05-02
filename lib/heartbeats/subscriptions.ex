defmodule Heartbeats.Subscriptions do
  @moduledoc """
  Replicated in-memory store for `Heartbeats.Subscription` records.

  Each node holds the full set of subscriptions in a local ETS table. Writes
  (`put/1`, `delete/1`) broadcast over `Phoenix.PubSub` so every node's ETS
  converges. Reads are local ETS lookups.

  This replication is what lets surviving nodes take over a dead node's
  subscriptions: they already know about every subscription, so they can start
  workers for the ones the ring now assigns to them.
  """

  use GenServer

  alias Heartbeats.Subscription

  @table __MODULE__
  @topic "subscriptions"

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(Subscription.t()) :: :ok
  def put(%Subscription{} = sub) do
    :ets.insert(@table, {sub.id, sub})
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:put, sub})
    :ok
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    :ets.delete(@table, id)
    Phoenix.PubSub.broadcast(Heartbeats.PubSub, @topic, {:delete, id})
    :ok
  end

  @spec get(String.t()) :: {:ok, Subscription.t()} | :error
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, sub}] -> {:ok, sub}
      [] -> :error
    end
  end

  @spec all() :: [Subscription.t()]
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_id, sub} -> sub end)
  end

  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc """
  Stops every locally-running worker and clears this node's ETS table.

  Used by `Heartbeats.clear_all/0` to robustly purge state across the cluster
  without relying on PubSub-driven replication (which can leave orphaned
  workers if any broadcast was missed).
  """
  @spec purge_local() :: :ok
  def purge_local do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Heartbeats.WorkerSupervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Heartbeats.WorkerSupervisor, pid)
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Heartbeats.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:put, %Subscription{} = sub}, state) do
    :ets.insert(@table, {sub.id, sub})
    {:noreply, state}
  end

  def handle_info({:delete, id}, state) when is_binary(id) do
    :ets.delete(@table, id)
    {:noreply, state}
  end
end
